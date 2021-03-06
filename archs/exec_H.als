module exec_H[E]
open exec[E]

sig Exec_H extends Exec {
  atom : E -> E // atomicity relation
}{

  // the atom relation relates a consecutively-sequenced read/write pair
  atom in (R->W) & sb & sloc
    
  // there are no single-event RMWs
  no (R&W)

  // there are no such things as "atomic" and "non-atomic" locations
  no NAL

  // control dependencies are defined differently in assembly
  cd.sb in cd 
    
}

fun atom[e:PTag->E, X:Exec_H] : E->E {
  (univ - e[rm_EV]) <: X.atom :> (univ - e[rm_EV]) }
