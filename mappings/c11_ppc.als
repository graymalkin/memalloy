/*
A C11-to-Power mapping.
*/

open ../archs/exec_C[SE] as SW
open ../archs/exec_ppc[HE] as HW

module c11_ppc[SE,HE]

pred apply_map[
  X : SW/Exec_C, X' : HW/Exec_PPC, 
  map : SE -> HE
] {

  // every read/write event in SW is mapped to at least one HW event
  map in X.(R+W) one -> some X'.ev

  // there are no no-ops
  X.ev in X.(R + W + F)
  X'.ev in X'.(R + W)
  
  // a non-atomic or relaxed read compiles to a single read
  all e : X.((R - W) - acq) {
    one e.map
    e.map in X'.R
  }
      
  // an acquire read compiles to a read followed by
  // a control fence, with control dependencies inserted between the
  // read and every event that is sequenced after it.
  all e : X.((R - W) & acq - sc) | let e1 = e.map {
    one e1 
    e1 in X'.R
    e1 <: (X'.sb) in X'.(cd & isync)
  }
  
  // an SC read compiles to a full fence followed by a read 
  // followed by a control fence, with control dependencies inserted 
  // between the read and every event that is sequenced after it
  all e : X.((R - W) & sc) | let e1 = e.map {
    one e1
    e1 in X'.R
    (X'.sb) :> e1 in X'.sync
    e1 <: (X'.sb) in X'.(cd & isync)  
  }
  
  // a non-atomic or relaxed write compiles to a single write
  all e : X.((W - R) - rel) {
    one e.map
    e.map in X'.W
  }

  // a release write compiles to a lightweight fence followed 
  // by a write
  all e : X.((W - R) & rel - sc) | let e1 = e.map {
    one e1
    e1 in X'.W
    (X'.sb) :> e1 in X'.lwsync
  }
  
  // an SC write compiles to a full fence followed by a write
  all e : X.((W - R) & sc) | let e1 = e.map {
    one e1
    e1 in X'.W
    (X'.sb) :> e1 in X'.sync
  }
  
  // a relaxed RMW compiles to a read followed by a write, with 
  // control dependencies inserted between the read and every 
  // event that is sequenced after it
  all e : X.((R & W) - (acq + rel)) | some disj e1,e2 : X'.ev {
    e.map = e1+e2
    e1 in X'.R
    e2 in X'.W
    (e1 -> e2) in X'.atom & imm[X'.sb]
    e1 <: (X'.sb) in X'.cd  
  }

  // an acquire RMW compiles to a read followed by a write, 
  // followed by an isync, with control dependencies inserted 
  // between the read and every event that is sequenced after it
  all e : X.((R & W & acq) - (rel + sc)) | some disj e1,e2 : X'.ev {
    e.map = e1+e2
    e1 in X'.R
    e2 in X'.W
    (e1 -> e2) in X'.atom & imm[X'.sb]
    e1 <: (X'.sb) in X'.(cd & isync)  
  }

  // a release RMW compiles to an lwsync, followed by a read, followed by
  // a write, with control dependencies inserted between the read and
  // every event that is sequenced after it
  all e : X.((R & W & rel) - (acq + sc)) | some disj e1,e2 : X'.ev {
    e.map = e1+e2
    e1 in X'.R
    e2 in X'.W
    (e1 -> e2) in X'.atom & imm[X'.sb]
    (X'.sb) :> e1 in X'.lwsync
    e1 <: (X'.sb) in X'.cd
  }

  // an acquire/release RMW compiles to an lwsync, followed by a read,
  // followed by a write, followed by an isync, with control
  // dependencies inserted between the read and every event that is
  // sequenced after it
  all e : X.((R & W & rel & acq) - sc) | some disj e1,e2 : X'.ev {
    e.map = e1+e2
    e1 in X'.R
    e2 in X'.W
    (e1 -> e2) in X'.atom & imm[X'.sb]
    (X'.sb) :> e1 in X'.lwsync
    e1 <: (X'.sb) in X'.(cd & isync)
  }

  // an SC RMW compiles to an sync, followed by a read, followed by
  // a write, followed by an isync, with control dependencies inserted
  // between the read and every event that is sequenced after it
  all e : X.(R & W & sc) | some disj e1,e2 : X'.ev {
    e.map = e1+e2
    e1 in X'.R
    e2 in X'.W
    (e1 -> e2) in X'.atom & imm[X'.sb]
    (X'.sb) :> e1 in X'.sync
    e1 <: (X'.sb) in X'.(cd & isync)
  }

  // release/acquire fences compile to lightweight fences
  all e : X.(F & (acq + rel) - sc) {
    (X.sb) . (stor[e]) . (X.sb) = map . (X'.lwsync) . ~map
  }
      
  // SC fences compile to full fences
  all e : X.(F & sc) {
    (X.sb) . (stor[e]) . (X.sb) = map . (X'.sync) . ~map
  }
 
  // sb edges are preserved (but more may be introduced)
  X.sb in map . (X'.sb) . ~map
  
  // the mapping preserves rf
  X.rf = map . (X'.rf) . ~map

  // the mapping preserves co
  X.co = map . (X'.co) . ~map

  // the mapping preserves address dependencies
  X.ad = map . (X'.ad) . ~map

  // the mapping preserves data dependencies
  X.dd = map . (X'.dd) . ~map

  // the mapping preserves locations
  X.sloc = map . (X'.sloc) . ~map
    
  // ctrl dependencies are preserved (but more may be introduced)
  X.cd in map . (X'.cd) . ~map

  // the mapping preserves threads
  X.sthd = map . (X'.sthd) . ~map
  
}
