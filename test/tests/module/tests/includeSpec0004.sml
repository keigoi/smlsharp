(*
derived form include specification.

<pre>
  include sigid1 ... sigidN
</pre>
*)
signature SA = sig type t val x : t end;
signature SB = sig datatype dt = D val y : dt end;

signature S =
sig
  include SA SB
  val z : t * dt
end;
