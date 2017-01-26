open ../models_als/c11_simp[E] as M1
open ../models_als/c11_orig[E] as M2

sig E {}

pred gp [X : Exec_C] {     

  // The execution is forbidden in M1
  not(M1/consistent[none,X])
  M1/dead[none,X]

  // The execution is allowed (and not faulty) in M2
  M2/consistent[none,X]

  // Prefer fewer RMWs
  //no_RMWs[X]
  lone (R[none,X] & W[none,X]) 

  // Prefer solutions with total sb per thread
  //total_sb[none,X]  
    
}

run gp for exactly 1 Exec, 4 E expect 0
// <1s

run gp for exactly 1 Exec, 5 E expect 1
// Soln is similar to Batty et al. (POPL'16) but quite a bit simpler.
// <1s


