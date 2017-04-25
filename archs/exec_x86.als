module exec_x86[E]
open exec_H[E]

sig Exec_X86 extends Exec_H {
  locked : set E, // atomic events
  mfence : set E // memory fence
}{

  mfence in F
    
  // only RMWs can be locked
  locked in univ.atom + atom.univ

  // the atom relation only relates locked instructions
  atom in (locked -> locked)
}

fun locked[e:E, X:Exec_X86, ad,cd,dd,mfence:E->E] : set E { X.locked - e }
fun mfence[e:E, X:Exec_X86, ad,cd,dd,mfence_:E->E] : E->E { mfence_ - (univ -> e) - (e -> univ) }
