(**
 * generate machine code
 *
 * @copyright (c) 2013 Tohoku University.
 * @author UENO Katsuhiro
 *)
structure MachineCodeGen : sig

  val compile : InterfaceName.dependency
                -> ANormal.program
                -> MachineCode.program

end =
struct

  structure A = ANormal
  structure M = MachineCode
  structure T = Types
  structure R = RuntimeTypes
  structure P = BuiltinPrimitive
  structure B = BuiltinTypes

  fun optionToList NONE = nil
    | optionToList (SOME x) = [x]

  val intTy = (B.intTy, R.INT32ty)
  fun intConst n =
      M.ANCONST {const = M.NVINT32 n, ty = intTy}

  val unitTy = (BuiltinTypes.unitTy, R.UNITty)
  val unitConst =
      M.ANCONST {const = M.NVUNIT, ty = unitTy}

  fun sizeTy ty = (T.SINGLETONty (T.SIZEty ty), R.UINT32ty)
  fun tagTy ty = (T.SINGLETONty (T.TAGty ty), R.UINT32ty)
  val wordTy = (BuiltinTypes.wordTy, R.UINT32ty)
  val boxedTy = (BuiltinTypes.boxedTy, R.BOXEDty)

  val empty = fn x:M.mcexp => x
  fun mid m = fn (mids, last):M.mcexp => (m::mids, last):M.mcexp
  fun last l = (nil, l):M.mcexp

  fun tagExp ((ty, rty):M.ty) =
      let
        val tag = TypeLayout2.tagOf rty
      in
        M.ANCONST {const = M.NVTAG {tag = tag, ty = ty}, ty = tagTy ty}
      end

  fun wordToTag (tagExp, valueTy) =
      case tagExp of
        M.ANCONST {const = M.NVWORD32 0w0, ...} =>
        M.ANCONST {const = M.NVTAG {tag=R.TAG_UNBOXED, ty=valueTy},
                   ty = tagTy valueTy}
      | M.ANCONST {const = M.NVWORD32 _, ...} =>
        M.ANCONST {const = M.NVTAG {tag=R.TAG_BOXED, ty=valueTy},
                   ty = tagTy valueTy}
      | _ =>
        M.ANCAST {exp = tagExp,
                  expTy = wordTy,
                  targetTy = tagTy valueTy,
                  runtimeTyCast = true}

  fun Int32_mul_unsafe (resultVar, op1, op2, loc) =
      mid (M.MCPRIMAPPLY
             {resultVar = resultVar,
              primInfo =
                {primitive = P.Int32_mul_unsafe,
                 ty = {boundtvars = BoundTypeVarID.Map.empty,
                       argTyList = [B.intTy, B.intTy],
                       resultTy = B.intTy}},
              argExpList = [op1, op2],
              argTyList = [intTy, intTy],
              resultTy = intTy,
              instTyList = [],
              instTagList = [],
              instSizeList = [],
              loc = loc})

  fun Alloc {resultVar, objType, payloadSize, allocSize, initExp, loc} =
      mid (M.MCALLOC
             {resultVar = resultVar,
              objType = objType,
              payloadSize = payloadSize,
              allocSize = allocSize,
              loc = loc})
      o initExp
      o mid M.MCALLOC_COMPLETED

  fun switchByTag {tagExp, tagOfTy, ifBoxed, ifUnboxed, loc} =
      let
        val nextLabel = FunLocalLabel.generate nil
        val ifBoxedLabel = FunLocalLabel.generate nil
        val ifUnboxedLabel = FunLocalLabel.generate nil
        val goto : M.mcexp =
            (nil, M.MCGOTO {id = nextLabel, argList = nil, loc = loc})
        val ifBoxedBlock =
            fn K => (nil, M.MCLOCALCODE
                            {id = ifBoxedLabel,
                             recursive = false,
                             argVarList = nil,
                             bodyExp = ifBoxed goto,
                             nextExp = K,
                             loc = loc}) : M.mcexp
        val ifUnboxedBlock =
            fn K => (nil, M.MCLOCALCODE
                            {id = ifUnboxedLabel,
                             recursive = false,
                             argVarList = nil,
                             bodyExp = ifUnboxed goto,
                             nextExp = K,
                             loc = loc}) : M.mcexp
      in
        fn K =>
           (nil,
            M.MCLOCALCODE
              {id = nextLabel,
               recursive = false,
               argVarList = nil,
               bodyExp = K,
               loc = loc,
               nextExp =
                 (ifBoxedBlock o ifUnboxedBlock)
                   (nil,
                    M.MCSWITCH
                      {switchExp = tagExp,
                       expTy = tagTy tagOfTy,
                       branches =
                         [(M.NVTAG {tag = R.TAG_UNBOXED, ty = tagOfTy},
                           ifUnboxedLabel)],
                       default = ifBoxedLabel,
                       loc = loc})})
      end

  fun arrayBytes (numElems, elemSize, elemTy:M.ty, loc) =
      let
        val sizeVar = {id = VarID.generate (), ty = intTy}
      in
        (Int32_mul_unsafe
           (sizeVar,
            M.ANCAST {exp = elemSize,
                      expTy = sizeTy (#1 elemTy),
                      targetTy = intTy,
                      runtimeTyCast = true},
            numElems,
            loc),
         M.ANVAR sizeVar)
      end

  fun allocArray {resultVar, resultTy, objType, elemTy, elemTag, elemSize,
                  numElems, loc} =
      let
        val (proc1, sizeExp) = arrayBytes (numElems, elemSize, elemTy, loc)
        val proc2 =
            Alloc
              {resultVar = resultVar,
               objType = objType,
               payloadSize = sizeExp,
               allocSize = sizeExp,
               initExp =
                 switchByTag
                   {tagExp = elemTag,
                    tagOfTy = #1 elemTy,
                    ifBoxed =
                      (* initialize with NULL *)
                      mid (M.MCBZERO
                            {recordExp = M.ANVAR resultVar,
                             recordSize = sizeExp,
                             loc = loc}),
                    ifUnboxed = empty,
                    loc = loc},
               loc = loc}
      in
        proc1 o proc2
      end

  fun mask (subst, vars) =
      foldl (fn ({id,...}:A.varInfo, subst) =>
                if VarID.Map.inDomain (subst, id)
                then #1 (VarID.Map.remove (subst, id))
                else subst)
            subst
            vars

  fun compileValue subst value =
      case value of
        A.ANCONST _ => value
      | A.ANBOTTOM => value
      | A.ANCAST {exp, expTy, targetTy, runtimeTyCast} =>
        A.ANCAST {exp = compileValue subst exp, expTy = expTy,
                  targetTy = targetTy, runtimeTyCast = runtimeTyCast}
      | A.ANVAR {id, ty} =>
        case VarID.Map.find (subst, id) of
          NONE => value
        | SOME value => value

  fun compileAddress subst loc address =
      case address of
        A.AAPTR ptrExp =>
        M.MAPTR (compileValue subst ptrExp)
      | A.AARECORDFIELD {recordExp, fieldIndex} =>
        M.MARECORDFIELD {recordExp = compileValue subst recordExp,
                         fieldIndex = compileValue subst fieldIndex}
      | A.AAARRAYELEM {arrayExp, elemSize, elemIndex} =>
        M.MAARRAYELEM {arrayExp = compileValue subst arrayExp,
                       elemSize = compileValue subst elemSize,
                       elemIndex = compileValue subst elemIndex}

  fun compileInitField subst dstAddr loc (fieldTy, initField) =
      case initField of
        A.INIT_VALUE value =>
        mid (M.MCSTORE {dstAddr = dstAddr,
                        srcExp = compileValue subst value,
                        srcTy = fieldTy,
                        barrier = false,
                        loc = loc})
      | A.INIT_COPY {srcExp, fieldSize} =>
        (* initializer does not need write barrier *)
        mid (M.MCMEMCPY_FIELD
               {dstAddr = dstAddr,
                srcAddr = M.MAPACKED (compileValue subst srcExp),
                copySize = compileValue subst fieldSize,
                loc = loc})
      | A.INIT_IF {tagExp, tagOfTy, ifBoxed, ifUnboxed} =>
        switchByTag
          {tagExp = compileValue subst tagExp,
           tagOfTy = tagOfTy,
           ifBoxed = compileInitField subst dstAddr loc (fieldTy, ifBoxed),
           ifUnboxed = compileInitField subst dstAddr loc (fieldTy, ifUnboxed),
           loc = loc}

  fun compileRecordField subst objPtrVar loc {fieldExp, fieldTy, fieldIndex} =
      let
        val dstAddr =
            M.MARECORDFIELD
              {recordExp = M.ANVAR objPtrVar,
               fieldIndex = compileValue subst fieldIndex}
      in
        compileInitField subst dstAddr loc (fieldTy, fieldExp)
      end

  fun compileRecordFieldList subst objPtrVar loc fields =
      foldl (fn (x,z) => z o compileRecordField subst objPtrVar loc x)
            empty
            fields

  fun compileRecordBitmap subst objPtrVar loc {bitmapIndex, bitmapExp} =
      let
        val dstAddr =
            M.MAOFFSET {base = M.ANVAR objPtrVar,
                        offset = compileValue subst bitmapIndex}
      in
        mid (M.MCSTORE {dstAddr = dstAddr,
                        srcExp = compileValue subst bitmapExp,
                        srcTy = wordTy,
                        barrier = false,
                        loc = loc})
      end

  fun compileRecordBitmapList subst objPtrVar loc bitmaps =
      foldl (fn (x,z) => z o compileRecordBitmap subst objPtrVar loc x)
            empty
            bitmaps

  fun compilePrim subst {resultVar, resultTy, primInfo = {primitive, ty},
                         argExpList, argTyList, instTyList, instTagList,
                         instSizeList, loc} =
      case (primitive, instTyList, instTagList, instSizeList, argExpList) of
        (P.Array_alloc_unsafe, [ty], [tag], [size], [len]) =>
        (allocArray
           {resultVar = resultVar,
            resultTy = resultTy,
            objType = M.OBJTYPE_ARRAY tag,
            elemTy = ty,
            elemTag = tag,
            elemSize = size,
            numElems = len,
            loc = loc},
         mask (subst, [resultVar]))
      | (P.Array_alloc_unsafe, _, _, _, _) =>
        raise Bug.Bug "compileExp: Array_alloc_unsafe"

      | (P.Vector_alloc_unsafe, [ty], [tag], [size], [len]) =>
        (allocArray
           {resultVar = resultVar,
            resultTy = resultTy,
            (* FIXME: the type of tag *)
            objType = M.OBJTYPE_VECTOR (wordToTag (tag, #1 boxedTy)),
            elemTy = ty,
            elemTag = tag,
            elemSize = size,
            numElems = len,
            loc = loc},
         mask (subst, [resultVar]))
      | (P.Vector_alloc_unsafe, _, _, _, _) =>
        raise Bug.Bug "compileExp: Vector_alloc_unsafe"

      | (P.Array_copy_unsafe, [ty], [tag], [size],
         [src, si, dst, di, len]) =>
        (switchByTag
           {tagExp = tag,
            tagOfTy = #1 ty,
            ifBoxed =
              mid (M.MCMEMMOVE_BOXED_ARRAY
                     {srcArray = src,
                      srcIndex = si,
                      dstArray = dst,
                      dstIndex = di,
                      numElems = len,
                      loc = loc}),
            ifUnboxed =
              mid (M.MCMEMMOVE_UNBOXED_ARRAY
                     {srcAddr = M.MAARRAYELEM
                                  {arrayExp = src,
                                   elemSize = size,
                                   elemIndex = si},
                      dstAddr = M.MAARRAYELEM
                                  {arrayExp = dst,
                                   elemSize = size,
                                   elemIndex = di},
                      numElems = len,
                      elemSize = size,
                      loc = loc}),
            loc = loc},
         VarID.Map.insert (subst, #id resultVar, unitConst))
      | (P.Array_copy_unsafe, _, _, _, _) =>
        raise Bug.Bug "compilePrim: Array_copy_unsafe"

      | (P.Boxed_deref, [], [], [], [ptr, index]) =>
        (mid (M.MCLOAD
                {resultVar = resultVar,
                 srcAddr = M.MAOFFSET {base = ptr, offset = index},
                 loc = loc}),
         mask (subst, [resultVar]))
      | (P.Boxed_deref, _, _, _, _) =>
        raise Bug.Bug "compilePrim: Boxed_deref"

      | (P.Ptr_dup, [], [], [], [ptr, tag, size]) =>
        (Alloc
           {resultVar = resultVar,
            objType = M.OBJTYPE_VECTOR tag, (* FIXME: the type of tag *)
            payloadSize = size,
            allocSize = size,
            initExp =
              mid (M.MCMEMCPY_FIELD
                     {dstAddr = M.MAARRAYELEM
                                  {arrayExp = M.ANVAR resultVar,
                                   elemSize = size,
                                   elemIndex = intConst 0},
                      srcAddr = M.MAPTR ptr,
                      copySize = size,
                      loc = loc}),
            loc = loc},
         mask (subst, [resultVar]))
      | (P.Ptr_dup, _, _, _, _) =>
        raise Bug.Bug "compilePrim: Ptr_dup"

      | (P.M prim, _, _, _, _) =>
        (mid (M.MCPRIMAPPLY {resultVar = resultVar,
                             primInfo = {primitive = prim, ty = ty},
                             argExpList = argExpList,
                             argTyList = argTyList,
                             resultTy = resultTy,
                             instTyList = instTyList,
                             instTagList = instTagList,
                             instSizeList = instSizeList,
                             loc = loc}),
         mask (subst, [resultVar]))

  fun compileExp subst anexp =
      case anexp of
        A.ANINTINF {resultVar, dataLabel, nextExp, loc} =>
        mid (M.MCINTINF
               {resultVar = resultVar,
                dataLabel = dataLabel,
                loc = loc})
            (compileExp (mask (subst, [resultVar])) nextExp)
      | A.ANFOREIGNAPPLY {resultVar, funExp, attributes, argExpList,
                          handler, nextExp, loc} =>
        mid (M.MCFOREIGNAPPLY
               {resultVar = resultVar,
                funExp = compileValue subst funExp,
                attributes = attributes,
                argExpList = map (compileValue subst) argExpList,
                handler = handler,
                loc = loc})
            (compileExp (mask (subst, optionToList resultVar)) nextExp)
      | A.ANEXPORTCALLBACK {resultVar, codeExp, closureEnvExp, instTyvars,
                            nextExp, loc} =>
        mid (M.MCEXPORTCALLBACK
               {resultVar = resultVar,
                codeExp = compileValue subst codeExp,
                closureEnvExp = compileValue subst closureEnvExp,
                instTyvars = instTyvars,
                loc = loc})
            (compileExp (mask (subst, [resultVar])) nextExp)
      | A.ANEXVAR {resultVar, id, nextExp, loc} =>
        mid (M.MCEXVAR
               {resultVar = resultVar,
                id = id,
                loc = loc})
            (compileExp (mask (subst, [resultVar])) nextExp)
      | A.ANPACK {resultVar, exp, expTy, nextExp, loc} =>
        let
          val size = intConst (TypeLayout2.sizeOf (#2 expTy))
          val resultTy = (#1 expTy, R.BOXEDty)
        in
          Alloc
            {resultVar = resultVar,
             objType = M.OBJTYPE_VECTOR (tagExp expTy),
             payloadSize = size,
             allocSize = size,
             initExp =
               mid (M.MCSTORE
                      {dstAddr = M.MAPACKED (M.ANVAR resultVar),
                       srcExp = compileValue subst exp,
                       srcTy = expTy,
                       barrier = false,
                       loc = loc}),
             loc = loc}
            (compileExp (mask (subst, [resultVar])) nextExp)
        end
      | A.ANUNPACK {resultVar, exp, nextExp, loc} =>
        mid (M.MCLOAD
               {resultVar = resultVar,
                srcAddr = M.MAPACKED (compileValue subst exp),
                loc = loc})
            (compileExp (mask (subst, [resultVar])) nextExp)
      | A.ANDUP {resultVar, srcAddr, valueSize, nextExp, loc} =>
        let
          val valueSize = compileValue subst valueSize
        in
          Alloc
            {resultVar = resultVar,
             objType = M.OBJTYPE_UNBOXED_VECTOR,
             payloadSize = valueSize,
             allocSize = valueSize,
             initExp =
               mid (M.MCMEMCPY_FIELD
                      {dstAddr = M.MAPACKED (M.ANVAR resultVar),
                       srcAddr = compileAddress subst loc srcAddr,
                       copySize = valueSize,
                       loc = loc}),
             loc = loc}
            (compileExp (mask (subst, [resultVar])) nextExp)
        end
      | A.ANLOAD {resultVar, srcAddr, nextExp, loc} =>
        mid (M.MCLOAD
               {resultVar = resultVar,
                srcAddr = compileAddress subst loc srcAddr,
                loc = loc})
            (compileExp (mask (subst, [resultVar])) nextExp)
      | A.ANPRIMAPPLY {resultVar, primInfo, argExpList,
                       instTyList, instTagList,
                       argTyList, resultTy, instSizeList, nextExp, loc} =>
        let
          val (proc1, subst) =
              compilePrim
                subst
                {resultVar = resultVar,
                 resultTy = resultTy,
                 primInfo = primInfo,
                 argExpList = map (compileValue subst) argExpList,
                 argTyList = argTyList,
                 instTyList = instTyList,
                 instTagList = map (compileValue subst) instTagList,
                 instSizeList = map (compileValue subst) instSizeList,
                 loc = loc}
        in
          proc1
            (compileExp subst nextExp)
        end
      | A.ANBITCAST {resultVar, exp, expTy, targetTy, nextExp, loc} =>
        mid (M.MCBITCAST
               {resultVar = resultVar,
                exp = compileValue subst exp,
                expTy = expTy,
                targetTy = targetTy,
                loc = loc})
            (compileExp (mask (subst, [resultVar])) nextExp)
      | A.ANCALL {resultVar, codeExp, closureEnvExp, argExpList, nextExp,
                  handler, loc} =>
        let
          val resultTy = #ty resultVar
          val (resultVar, subst) =
              if #2 resultTy = R.UNITty
              then (NONE, VarID.Map.insert (subst, #id resultVar, unitConst))
              else (SOME resultVar, mask (subst, [resultVar]))
        in
          mid (M.MCCALL
                 {resultVar = resultVar,
                  resultTy = resultTy,
                  codeExp = compileValue subst codeExp,
                  closureEnvExp = Option.map (compileValue subst) closureEnvExp,
                  argExpList = map (compileValue subst) argExpList,
                  tail = false,
                  handler = handler,
                  loc = loc})
              (compileExp subst nextExp)
        end
      | A.ANTAILCALL {resultTy, codeExp, closureEnvExp, argExpList, loc} =>
        let
          val (resultVar, retValue) =
              if #2 resultTy = R.UNITty
              then (NONE, unitConst)
              else
                let
                  val resultVar = {id = VarID.generate (), ty = resultTy}
                in
                  (SOME resultVar, M.ANVAR resultVar)
                end
        in
          mid (M.MCCALL
                 {resultVar = resultVar,
                  resultTy = resultTy,
                  codeExp = compileValue subst codeExp,
                  closureEnvExp = Option.map (compileValue subst) closureEnvExp,
                  argExpList = map (compileValue subst) argExpList,
                  tail = true,
                  handler = NONE,
                  loc = loc})
            (last (M.MCRETURN {value = retValue, loc = loc}))
        end
      | A.ANRECORD {resultVar, fieldList, isMutable, clearPad,
                    allocSizeExp, bitmaps, nextExp, loc} =>
        let
          val allocSizeExp = compileValue subst allocSizeExp
          val proc1 =
              if clearPad
              then mid (M.MCBZERO
                          {recordExp = M.ANVAR resultVar,
                           recordSize = allocSizeExp,
                           loc = loc})
              else empty
          val proc2 =
              compileRecordFieldList subst resultVar loc fieldList
          val proc3 =
              compileRecordBitmapList subst resultVar loc bitmaps
          val payloadSize =
              case bitmaps of
                {bitmapIndex, ...}::_ => compileValue subst bitmapIndex
              | _ => raise Bug.Bug "compileExp: ANRECORD: no bitmap record"
        in
          Alloc
            {resultVar = resultVar,
             objType = M.OBJTYPE_RECORD, (* FIXME: ANRECORD: objtype depends on bitmap *)
             payloadSize = payloadSize,
             allocSize = allocSizeExp,
             initExp = proc1 o proc2 o proc3,
             loc = loc}
            (compileExp (mask (subst, [resultVar])) nextExp)
        end
      | A.ANMODIFY {resultVar, recordExp, indexExp, valueExp, valueTy,
                    nextExp, loc} =>
        let
          val addr =
              M.MARECORDFIELD
                {recordExp = M.ANVAR resultVar,
                 fieldIndex = compileValue subst indexExp}
          val copySizeVar = {id = VarID.generate (), ty = wordTy}
          val srcRecord = compileValue subst recordExp
        in
          (mid (M.MCRECORDDUP_ALLOC
                  {resultVar = resultVar,
                   copySizeVar = copySizeVar,
                   recordExp = srcRecord,
                   loc = loc})
           o mid (M.MCRECORDDUP_COPY
                    {dstRecord = M.ANVAR resultVar,
                     srcRecord = srcRecord,
                     copySize = M.ANVAR copySizeVar,
                     loc = loc})
           o compileRecordField
               subst
               resultVar
               loc
               {fieldExp = valueExp,
                fieldTy = valueTy,
                fieldIndex = indexExp}
           o mid M.MCALLOC_COMPLETED)
            (compileExp (mask (subst, [resultVar])) nextExp)
        end
      | A.ANRETURN {value, ty, loc} =>
        last (M.MCRETURN
                {value = compileValue subst value,
                 loc = loc})
      | A.ANCOPY {srcExp, dstAddr, valueSize, nextExp, loc} =>
        mid (M.MCMEMCPY_FIELD
               {dstAddr = compileAddress subst loc dstAddr,
                srcAddr = M.MAPACKED (compileValue subst srcExp),
                copySize = compileValue subst valueSize,
                loc = loc})
            (compileExp subst nextExp)
      | A.ANSTORE {srcExp, srcTy, dstAddr, nextExp, loc} =>
        mid (M.MCSTORE
               {srcExp = compileValue subst srcExp,
                srcTy = srcTy,
                dstAddr = compileAddress subst loc dstAddr,
                barrier = case srcTy of (_, R.BOXEDty) => true | _ => false,
                loc = loc})
            (compileExp subst nextExp)
      | A.ANEXPORTVAR {id, ty, valueExp, nextExp, loc} =>
        mid (M.MCEXPORTVAR
               {id = id,
                ty = ty,
                valueExp = compileValue subst valueExp,
                loc = loc})
            (compileExp subst nextExp)
      | A.ANRAISE {argExp, cleanup, loc} =>
        last (M.MCRAISE
               {argExp = compileValue subst argExp,
                cleanup = cleanup,
                loc = loc})
      | A.ANHANDLER {nextExp, exnVar, id, handlerExp, cleanup, loc} =>
        last (M.MCHANDLER
                {nextExp = compileExp subst nextExp,
                 id = id,
                 exnVar = exnVar,
                 handlerExp = compileExp (mask (subst, [exnVar])) handlerExp,
                 cleanup = cleanup,
                 loc = loc})
      | A.ANSWITCH {switchExp, expTy, branches, default, loc} =>
        last (M.MCSWITCH
                {switchExp = compileValue subst switchExp,
                 expTy = expTy,
                 branches = branches,
                 default = default,
                 loc = loc})
      | A.ANGOTO {id, argList, loc} =>
        last (M.MCGOTO
                {id = id,
                 argList = map (compileValue subst) argList,
                 loc = loc})
      | A.ANLOCALCODE {id, recursive, argVarList, bodyExp, nextExp, loc} =>
        last (M.MCLOCALCODE
                {id = id,
                 recursive = recursive,
                 argVarList = argVarList,
                 bodyExp = compileExp (mask (subst, argVarList)) bodyExp,
                 nextExp = compileExp subst nextExp,
                 loc = loc})
      | A.ANUNREACHABLE =>
        last M.MCUNREACHABLE

  fun compileTopdec topdec =
      case topdec of
        A.ATFUNCTION {id, tyvarKindEnv, argVarList, closureEnvVar, bodyExp,
                      retTy, loc} =>
        M.MTFUNCTION
          {id = id,
           tyvarKindEnv = tyvarKindEnv,
           argVarList = argVarList,
           closureEnvVar = closureEnvVar,
           frameSlots = SlotID.Map.empty,
           bodyExp = compileExp VarID.Map.empty bodyExp,
           retTy = retTy,
           loc = loc}
      | A.ATCALLBACKFUNCTION {id, tyvarKindEnv, argVarList, closureEnvVar,
                              bodyExp, attributes, retTy, cleanupHandler,
                              loc} =>
        M.MTCALLBACKFUNCTION
          {id = id,
           tyvarKindEnv = tyvarKindEnv,
           argVarList = argVarList,
           closureEnvVar = closureEnvVar,
           bodyExp = compileExp VarID.Map.empty bodyExp,
           frameSlots = SlotID.Map.empty,
           attributes = attributes,
           retTy = retTy,
           cleanupHandler = cleanupHandler,
           loc = loc}

  fun compile dependency
              ({topdata, topdecs, topExp, topCleanupHandler}:A.program) =
      let
        val topdecs = map compileTopdec topdecs
        val topExp = compileExp VarID.Map.empty topExp
        val toplevel = {dependency = dependency,
                        frameSlots = SlotID.Map.empty,
                        bodyExp = topExp,
                        cleanupHandler = topCleanupHandler}
      in
        {topdata = topdata, topdecs = topdecs, toplevel = toplevel} : M.program
      end

end
