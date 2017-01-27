/*
A C11-to-Arm7 mapping, but avoiding fences at the start/end of threads.
JW: This mapping is probably not quite right.
*/

open ../archs/exec_C[SE] as SW
open ../archs/exec_arm7[HE] as HW

module c11_arm7_trimmed[SE,HE]

pred apply_map[
  X : SW/Exec_C, X' : HW/Exec_Arm7, 
  map : SE -> HE
] {

  //X.ev = SE
  //X'.ev = HE

  // every software event is mapped to at least one hardware event
  map in X.ev one -> some X'.ev

  // there are no no-ops on the software side
  X.ev in X.(R + W + F)
  
  // a non-atomic or relaxed read compiles to a single read
  all e : X.((R - W) - acq) {
    one e.map
    e.map in X'.R
  }
      
  // an acquire read compiles to a read followed by
  // a control fence, with control dependencies inserted between the read and 
  // every event that is sequenced after it.
  // NEW 6-Oct-2016: if the acquire read is *last* in its thread, forget the 
  // fence and dependencies.
  all e : X.((R - W) & acq - sc) | no e.(X.sb) => {
    // Case: e is last
    one e.map
    e.map in X'.R
  } else some disj e1,e2 : X'.ev { 
    // Case: e is not last
    e.map = e1+e2
    e1 in X'.R
    e2 in X'.isb
    (e1 -> e2) in imm[X'.sb] & X'.(cd - (ad + dd))
    all e' : X'.sb[e1] | (e1 -> e') in X'.cd
  }

  // an SC read compiles to a full fence followed by a read 
  // followed by a control fence, with control dependencies inserted 
  // between the read and every event that is sequenced after it
  // NEW 6-Oct-2016: if the SC read is *first* in its thread, forget the
  // first fence, and if the SC read is *last* in its thread, forget the 
  // second fence and dependencies.
  all e : X.((R - W) & sc) | no e.(X.sb) => (
    no (X.sb).e => {
      // Case: e is both first and last
      one e.map
      e.map in X'.R
    } else some disj e1,e2 : X'.ev {
      // Case: e is last but not first
      e.map = e1+e2
      e1 in X'.dmb
      e2 in X'.R
      (e1 -> e2) in imm[X'.sb]
    }
  ) else (
    no (X.sb).e => (some disj e1,e2 : X'.ev {
      // Case: e is first but not last
      e.map = e1+e2
      e1 in X'.R
      e2 in X'.isb
      (e1 -> e2) in imm[X'.sb] & X'.(cd - (ad + dd))
      all e' : X'.sb[e1] | (e1 -> e') in X'.cd
    }) else some disj e1,e2,e3 : X'.ev {
      // Case: e is neither first nor last
      e.map = e1+e2+e3
      e1 in X'.dmb
      e2 in X'.R
      e3 in X'.isb 
      (e1 -> e2) in imm[X'.sb]
      (e2 -> e3) in imm[X'.sb] & X'.(cd - (ad + dd))
      all e' : X'.sb[e2] | (e2 -> e') in X'.cd
    }
  )
  
  // a non-atomic or relaxed write compiles to a single write
  all e : X.((W - R) - rel) {
    one e.map
    e.map in X'.W
  }

  // a release write compiles to a lightweight fence followed 
  // by a write
  // NEW 6-Oct-2016: if the release write is *first* in its thread, forget the
  // fence.
  all e : X.((W - R) & rel - sc) | no (X.sb).e => {
    // Case: e is first
    one e.map
    e.map in X'.W
  } else some disj e1,e2 : X'.ev {
    // Case: e is not first
    e.map = e1+e2
    e1 in X'.dmb
    e2 in X'.W 
    (e1 -> e2) in imm[X'.sb]
  }
  
  // an SC write compiles to a full fence followed by a write
  // NEW 6-Oct-2016: if the SC write is *first* in its thread, forget the
  // fence.
  all e : X.((W - R) & sc) | no (X.sb).e => {
    // Case: e is first
    one e.map
    e.map in X'.W
  } else some disj e1,e2 : X'.ev {
    // Case: e is not first
    e.map = e1+e2
    e1 in X'.dmb
    e2 in X'.W
    (e1 -> e2) in imm[X'.sb]
  }
  
  // a relaxed RMW compiles to a read followed by a write, with 
  // control dependencies inserted between the read and every 
  // event that is sequenced after it
  all e : X.((R & W) - (acq + rel)) | some disj e1,e2 : X'.ev {
    e.map = e1+e2
    e1 in X'.R
    e2 in X'.W
    (e1 -> e2) in X'.atom
    all e' : X'.sb[e1] | (e1 -> e') in X'.cd
  }

  // an acquire RMW compiles to a read followed by a write, 
  // followed by an isync, with control dependencies inserted 
  // between the read and every event that is sequenced after it
  all e : X.((R & W & acq) - (rel + sc)) | some disj e1,e2,e3 : X'.ev {
    e.map = e1+e2+e3
    e1 in X'.R
    e2 in X'.W
    e3 in X'.isb
    (e1 -> e2) in X'.atom
    (e2 -> e3) in imm[X'.sb]
    (e1 -> e3) in X'.(cd - (ad + dd))
    all e' : X'.sb[e1] | (e1 -> e') in X'.cd
  }

  // a release RMW compiles to an lwsync, followed by a read, followed by
  // a write, with control dependencies inserted between the read and every 
  // event that is sequenced after it
  all e : X.((R & W & rel) - (acq + sc)) | some disj e1,e2,e3 : X'.ev {
    e.map = e1+e2+e3
    e1 in X'.dmb
    e2 in X'.R
    e3 in X'.W
    (e1 -> e2) in imm[X'.sb]
    (e2 -> e3) in X'.atom
    all e' : X'.sb[e2] | (e2 -> e') in X'.cd
  }

  // an acquire/release RMW compiles to an lwsync, followed by a read, followed by
  // a write, followed by an isync, with control dependencies inserted between 
  // the read and every event that is sequenced after it
  all e : X.((R & W & rel & acq) - sc) | some disj e1,e2,e3,e4 : X'.ev {
    e.map = e1+e2+e3+e4
    e1 in X'.dmb
    e2 in X'.R
    e3 in X'.W
    e4 in X'.isb
    (e1 -> e2) in imm[X'.sb]
    (e2 -> e3) in X'.atom
    (e3 -> e4) in imm[X'.sb]
    (e1 -> e3) in X'.(cd - (ad + dd))
    all e' : X'.sb[e2] | (e2 -> e') in X'.cd
  }

  // an SC RMW compiles to an hwsync, followed by a read, followed by
  // a write, followed by an isync, with control dependencies inserted between 
  // the read and every event that is sequenced after it
  all e : X.(R & W & sc) | some disj e1,e2,e3,e4 : X'.ev {
    e.map = e1+e2+e3+e4
    e1 in X'.dmb
    e2 in X'.R
    e3 in X'.W
    e4 in X'.isb
    (e1 -> e2) in imm[X'.sb]
    (e2 -> e3) in X'.atom
    (e3 -> e4) in imm[X'.sb]
    (e1 -> e3) in X'.(cd - (ad + dd))
    all e' : X'.sb[e2] | (e2 -> e') in X'.cd
  }

  // relaxed fences compile to no-ops
  all e : X.(F - (acq + rel)) {
    one e.map
    e.map in X'.(ev - (R + W + F))
  }

  // release/acquire fences compile to lightweight fences
  all e : X.(F & (acq + rel) - sc) {
    one e.map
    e.map in X'.dmb
  }
     
  // SC fences compile to full fences
  all e : X.(F & sc) {
    one e.map 
    e.map in X'.dmb
  }
 
  // the mapping is allowed to introduce extra sb edges within a
  // thread - partly because the compilation scheme may introduce
  // extra events, and partly because the compilation scheme may
  // need to linearise a partial sb in the source.
  (all e1,e2 : X.ev | 
	((e1 -> e2) in (X.sb)) implies ((e1.map -> e2.map) in (X'.sb)))
  
  // the mapping preserves rf
  X.rf = map . (X'.rf) . ~map

  // the mapping preserves co
  X.co = map . (X'.co) . ~map

  // the mapping preserves address dependencies
  X.ad = map . (X'.ad) . ~map

  // the mapping preserves data dependencies
  X.dd = map . (X'.dd) . ~map

  // the mapping preserves locations
  (X.sloc) = map . (X'.sloc) . ~map
    
  // every ctrl dependency in the software induces zero or
  // more ctrl dependencies in the hardware, depending on
  // how many hardware instructions the dependent software 
  // instruction maps to.
  (all e1,e2 : X.ev |
	(((e1 -> e2) in X.cd) && some e1.map) implies
	  (some e1' : e1.map | (e1' -> e2.map) in X'.cd))
  
  // every ctrl dependency in the hardware is obtained 
  // from an existing ctrl dependency in the software, or
  // else is introduced by the scheme.
  (all e1',e2' : X'.ev | ((e1' -> e2') in X'.cd) implies
	(some e1,e2 : X.ev | e1' in e1.map && e2' in e2.map &&
      (e1 -> e2) in rc[X.cd]))

  // the mapping preserves threads
  (X'.sthd) = ~map . (X.sthd) . map
  
}
