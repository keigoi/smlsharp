(**
 * main for minismlsharp
 * @copyright (c) 2013, Tohoku University.
 * @author UENO Katsuhiro
 *)

(* dummy *)
structure RunLoop =
struct
  type options =
       {systemBaseDir : Filename.filename,
        stdPath : Filename.filename list,
        loadPath : Filename.filename list,
        LDFLAGS : string list,
        LIBS : string list,
        llvmOptions : LLVMUtils.compile_options,
        errorOutput : TextIO.outstream}
  fun interactive (_:options) (_:Top.toplevelContext) = ()
end

;
_use "./SimpleMain.sml"
