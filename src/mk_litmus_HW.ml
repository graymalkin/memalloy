(*
MIT License

Copyright (c) 2017 by John Wickerson.

Permission is hereby granted, free of charge, to any person obtaining
a copy of this software and associated documentation files (the
"Software"), to deal in the Software without restriction, including
without limitation the rights to use, copy, modify, merge, publish,
distribute, sublicense, and/or sell copies of the Software, and to
permit persons to whom the Software is furnished to do so, subject to
the following conditions:

The above copyright notice and this permission notice shall be
included in all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND,
EXPRESS OR IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND
NONINFRINGEMENT. IN NO EVENT SHALL THE AUTHORS OR COPYRIGHT HOLDERS BE
LIABLE FOR ANY CLAIM, DAMAGES OR OTHER LIABILITY, WHETHER IN AN ACTION
OF CONTRACT, TORT OR OTHERWISE, ARISING FROM, OUT OF OR IN CONNECTION
WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE SOFTWARE.
*)

(** Converting a generic litmus test into a hardware litmus test *)

open! Format
open! General_purpose
open Litmus

type mk_litmus_state = {
    loc_map : (Location.t, Register.t) Assoc.t; (** mapping locations to registers *)
    next_reg : int; (** next register *)
    next_lbl : int; (** next label *)
    next_sentinel : int; (** next sentinel value *)
    current_post: (address, Value.t) Assoc.t; (** postcondition *)
    next_txid : int; (** next transaction id *)
  }

let get_fresh_reg tid state =
  let r = state.next_reg in
  {state with next_reg = r + 1}, (tid, r)

let get_fresh_lbl state =
  let lbl = state.next_lbl in
  {state with next_lbl = lbl + 1}, lbl

let get_fresh_sentinel state =
  let sentinel = state.next_sentinel in
  {state with next_sentinel = sentinel + 1}, sentinel

let add_to_loc_map (l, r) state =
  {state with loc_map = (l, r) :: state.loc_map}

let update_post f state =
  {state with current_post = f (state.current_post)}

let get_fresh_txid state =
  let txid = state.next_txid in
  {state with next_txid = txid + 1}, txid
  
(** [remove_Ifs r cs] removes from the component list [cs] all if-statements that test the value of the register [r] *)
let rec remove_Ifs r = function
  | [] -> []
  | Basic b :: cs -> Basic b :: remove_Ifs r cs
  | If (r',v,cs') :: cs ->
     let cs' = remove_Ifs r cs' in
     (if r=r' then cs' else [If(r',v,cs')]) @ remove_Ifs r cs

(** [reduce_Ifs c] replaces [(if b then c1);c2] with [if b then (c1;c2)], which is fine when it is assumed that "cd;sb \subseteq cd" holds. *) 
let rec reduce_Ifs = function
  | [] -> []
  | Basic b :: cs ->
     Basic b :: reduce_Ifs cs
  | If (r,v,cs') :: cs ->
     If (r,v,cs') :: reduce_Ifs (remove_Ifs r cs)

(** Builds various flavours of load/store instructions *)
let mk_Access dir attrs (dst, src, off, sta, imm, loc) = 
  let a = {
      Litmus_HW.dir = dir;
      dst = dst; src = src; off = off; sta = sta; imm = imm; loc = loc;
      is_exclusive = List.mem "X" attrs;
      is_acq_rel = List.mem "SCACQ" attrs || List.mem "SCREL" attrs
    }
  in Litmus_HW.Access a

(** Builds a load instruction *)
let mk_LD attrs (dst, src, off, loc) =
  mk_Access Litmus_HW.LD attrs (dst, src, off, None, None, loc)

(** Builds a store instruction *)
let mk_ST attrs (src, dst, off, sta, imm, loc) =
  mk_Access Litmus_HW.ST attrs (dst, src, off, sta, imm, loc)

(** Builds a MOV or an ADD instruction, depending on whether or not there is a data-dependency *)
let mk_MOV_or_ADD (r_src, v) = function
  | None -> Litmus_HW.MOV (r_src, v)
  | Some r_off_d -> Litmus_HW.ADD (r_src, r_off_d, v)
	    
(** Builds fake dependencies using exclusive-or instructions. Currently an instruction can have an address or data dependency only on a single instruction, but there's no good reason not to generalise to any number of instructions if required. *)
let rec hw_ins_of_exp tid state = function
  | Just n -> state, [], n, None
  | Madd (exp, r_dep) ->
     match hw_ins_of_exp tid state exp with
     | state, _, n, None ->
        let state, r_off = get_fresh_reg tid state in
        let il = [Litmus_HW.EOR (r_off, r_dep, r_dep)] in
        state, il, n, Some r_off
     | state, il, n, Some r_off ->
        let state, r_tmp = get_fresh_reg tid state in
        let il = il @ [
              Litmus_HW.EOR (r_tmp, r_dep, r_dep);
              Litmus_HW.ADDREG (r_off, r_off, r_tmp);
            ]
        in
        state, il, n, Some r_off

let is_tstart = function
  | Litmus_HW.TSTART (_, _) -> true
  | _ -> false

let get_last_tstart il =
  let tstarts = List.filter is_tstart il in
  if tstarts = [] then failwith "Missing TSTART";
  List.hd (List.rev tstarts)

let reg_of_tstart = function
  | Litmus_HW.TSTART (r, _) -> r
  | _ -> failwith "Not a TSTART!"

let last_txn_block il =
  List.rev (MyList.take (fun x -> not (is_tstart x)) (List.rev il))

(** Given the instruction list [il] determine whether we are currently in a txn block *)
let in_txn_block il =
  let rec walk = function
    | [] -> false
    | Litmus_HW.TCOMMIT :: _xs -> false
    | Litmus_HW.TSTART (_, _) :: _xs -> true
    | _ :: xs -> walk xs
  in
  walk (List.rev il)

let is_ld = function
  | Litmus_HW.Access a when a.Litmus_HW.dir = Litmus_HW.LD -> true
  | _ -> false

let dst_of_ld = function
  | Litmus_HW.Access a when a.Litmus_HW.dir = Litmus_HW.LD -> a.Litmus_HW.dst
  | _ -> failwith "Not a LD access!"

let expected_val_of_reg post r =
  try List.assoc (Reg r) post with
    Not_found -> failwith "Couldn't find register %a!" Register.pp r

let mk_st_excl_prologue arch_params tid state il =
  if in_txn_block il then
    let state, lbl = get_fresh_lbl state in
    let state, r_txn = get_fresh_reg tid state in
    let tabort_false = arch_params.Litmus_HW.mk_tabort r_txn 0xf in
    let lbl_succ = (sprintf "ExclSucc%d" lbl) in
    state, [ Litmus_HW.BEQ lbl_succ ] @ tabort_false @ [ Litmus_HW.LBL lbl_succ ]
  else
    state, [ Litmus_HW.BNZ (sprintf "ExclFail%d" tid) ]
               
(** [hw_ins_of_ins tid (locs, nr) ins] builds a sequence of HW instructions from a single generic instruction [ins]. The current thread identifier is [tid], the correspondence between locations and registers is in [locs], [nr] is the next register to use, and [nl] is the next label to use. *)
let hw_ins_of_ins arch_params tid state il = function
  | Load (r_dst, le), attrs ->
     let state, il_exp, l, r_off = hw_ins_of_exp tid state le in
     let state, r_src = get_fresh_reg tid state in
     let state = add_to_loc_map (l, r_src) state in
     let il_ld = [mk_LD attrs (r_dst, r_src, r_off, Some l)] in
     state, il @ il_exp @ il_ld
  | Store (le, ve), attrs
       when List.mem "X" attrs && arch_params.Litmus_HW.use_status_reg ->
     let state, il_exp1, l, r_off_a = hw_ins_of_exp tid state le in
     let state, il_exp2, v, r_off_d = hw_ins_of_exp tid state ve in
     let state, r_src = get_fresh_reg tid state in
     let state, r_dst = get_fresh_reg tid state in
     let state, r_status = get_fresh_reg tid state in
     let state = add_to_loc_map (l, r_dst) state in
     let il_st = [
         mk_MOV_or_ADD (r_src, v) r_off_d;
         mk_ST attrs (r_src, r_dst, r_off_a, Some r_status, Some v, Some l);
         Litmus_HW.CMP r_status; (* Fail if r_status!=0 *)
       ]
     in
     let state, il_st_prologue = mk_st_excl_prologue arch_params tid state il in
     state, il @ il_exp1 @ il_exp2 @ il_st @ il_st_prologue
  | Store (le, ve), attrs
       when List.mem "X" attrs
            && not arch_params.Litmus_HW.use_status_reg ->
     let state, il_exp1, l, r_off_a = hw_ins_of_exp tid state le in
     let state, il_exp2, v, r_off_d = hw_ins_of_exp tid state ve in
     let state, r_src = get_fresh_reg tid state in
     let state, r_dst = get_fresh_reg tid state in
     let state = add_to_loc_map (l, r_dst) state in
     let il_st = [
         mk_MOV_or_ADD (r_src, v) r_off_d;
         mk_ST attrs (r_src, r_dst, r_off_a, None, Some v, Some l)
       ]
     in
     let state, il_st_prologue = mk_st_excl_prologue arch_params tid state il in
     state, il @ il_exp1 @ il_exp2 @ il_st @ il_st_prologue
  | Store (le, ve), attrs when not (List.mem "X" attrs) ->
     let state, il_exp1, l, r_off_a = hw_ins_of_exp tid state le in
     let state, il_exp2, v, r_off_d = hw_ins_of_exp tid state ve in
     let state, r_src = get_fresh_reg tid state in
     let state, r_dst = get_fresh_reg tid state in
     let state = add_to_loc_map (l, r_dst) state in
     let il_st = [
         mk_MOV_or_ADD (r_src, v) r_off_d;
	 mk_ST attrs (r_src, r_dst, r_off_a, None, Some v, Some l)
       ]
     in
     state, il @ il_exp1 @ il_exp2 @ il_st
  | Cas _, _ -> failwith "No single-event RMWs in assembly!"
  | Fence, attrs ->
     let il_f =
       [Litmus_HW.HW_fence (arch_params.Litmus_HW.mk_fence attrs)]
     in
     state, il @ il_f
  | TxnBegin, _ ->
     let state, r_txn = get_fresh_reg tid state in
     let state, txid = get_fresh_txid state in
     let il_tbegin =
       arch_params.Litmus_HW.mk_tstart r_txn (sprintf "TxnFail%d" txid)
     in
     state, il @ il_tbegin
  | TxnEnd TxnCommit, _ ->
     let _ = assert (in_txn_block il) in
     let state, r_zero = get_fresh_reg tid state in
     let state, r_ok = get_fresh_reg tid state in
     let txid = state.next_txid - 1 in
     let success_lbl = sprintf "TxnSuccess%d" txid in
     let fail_lbl = sprintf "TxnFail%d" txid in
     let state = add_to_loc_map (-1, r_ok) state in
     let il_tcommit = [
         Litmus_HW.TCOMMIT;
         Litmus_HW.J success_lbl;
         Litmus_HW.LBL fail_lbl;
         Litmus_HW.MOV (r_zero, 0);
         mk_ST [] (r_zero, r_ok, None, None, Some 0, Some (-1));
         Litmus_HW.J (sprintf "Exit%d" tid);
         Litmus_HW.LBL success_lbl;
       ] in
     state, il @ il_tcommit
  | TxnEnd TxnAbort, _ ->
     let _ = assert (in_txn_block il) in
     let state, r_zero = get_fresh_reg tid state in
     let state, r_ok = get_fresh_reg tid state in
     let txid = state.next_txid - 1 in
     let fail_lbl = sprintf "TxnFail%d" txid in
     let last_tstart = get_last_tstart il in
     let tstart_reg = reg_of_tstart last_tstart in
     let txn_block = last_txn_block il in
     let lds = List.filter is_ld txn_block in
     let rs = List.rev (List.map dst_of_ld lds) in
     let vs = List.map (expected_val_of_reg state.current_post) rs in
     let state =
       update_post
         (Assoc.remove_assocs (List.map (fun r -> Reg r) rs)) state
     in
     let state, lbl = get_fresh_lbl state in
     let lbl = sprintf "Else%02d" lbl in
     let mk_eq r v =
       [ Litmus_HW.CMPIMM (r, v); Litmus_HW.BNZ lbl ]
     in
     let cond =
       List.fold_right (fun (r,v) acc -> acc @ mk_eq r v)
         (List.combine rs vs) []
     in
     let state, r_txn = get_fresh_reg tid state in
     let state, sentinel = get_fresh_sentinel state in
     let encoded = arch_params.Litmus_HW.encode_sentinel sentinel in
     let state, r_txn_status = get_fresh_reg tid state in
     let state = update_post ((@) [(Reg r_txn_status, encoded)]) state in
     let tabort_true = arch_params.Litmus_HW.mk_tabort r_txn sentinel in 
     let tabort_false = arch_params.Litmus_HW.mk_tabort r_txn 0xf in
     let state = add_to_loc_map (-1, r_ok) state in
     let il_tabort =
       cond
       @ tabort_true
       @ [ Litmus_HW.LBL lbl ]
       @ tabort_false
       @ [ Litmus_HW.MOV (r_zero, 0);
           mk_ST [] (r_zero, r_ok, None, None, Some 0, Some (-1));
           Litmus_HW.LBL fail_lbl ]
       @ arch_params.Litmus_HW.mk_tabort_handler r_txn_status tstart_reg
     in
     state, il @ il_tabort
  | ins, attr -> failwith "Not yet implemented! %a" pp_instr (ins, attr)

let is_st_excl = function
  | Litmus_HW.Access a ->
    a.Litmus_HW.dir = Litmus_HW.ST && a.Litmus_HW.is_exclusive
  | _ -> false

let is_tstart = function
  | Litmus_HW.TSTART (_, _) -> true
  | _ -> false

(** [can_fail il] holds iff the instruction list [il] contains
 * a failing instruction: a store-exclusive or a tstart. *)
let can_fail il =
  let is_failing_instr i =
    is_st_excl i || is_tstart i
  in
  List.exists is_failing_instr il

(** [hw_ins_of_components tid (locs,nr,nl,il) cs] convert a list [cs] of HW litmus test components into a list of HW instructions. The current thread identifier is [tid], the correspondence between locations and registers is in [locs], [nr] is the next register to use, [nl] is the next label to use, and [il] is the list of instructions produced so far. *)
let rec hw_ins_of_components arch_params tid (state,il) =
  function
  | [] when (List.exists is_st_excl il) ->
     (* TODO: Check that there exists a store-exclusive *inside a txn* *)
     let state, r_zero = get_fresh_reg tid state in
     let state, r_ok = get_fresh_reg tid state in
     let state = add_to_loc_map (-1, r_ok) state in
     let il = il @ [
       Litmus_HW.J (sprintf "Exit%d" tid);
       Litmus_HW.LBL (sprintf "ExclFail%d" tid);
       Litmus_HW.MOV (r_zero, 0);
       mk_ST [] (r_zero, r_ok, None, None, Some 0, Some (-1));
       Litmus_HW.LBL (sprintf "Exit%d" tid)
     ] in
     state, il
  | [] ->
     let il = il @ [Litmus_HW.LBL (sprintf "Exit%d" tid)] in
     state,il
  | Basic (ins,attrs) :: cs ->
     let state,il =
       hw_ins_of_ins arch_params tid state il (ins,attrs)
     in
     hw_ins_of_components arch_params tid (state,il) cs
  | If (r,_,cs') :: cs ->
     let state,lbl = get_fresh_lbl state in
     let lbl = sprintf "Else%02d" lbl in
     let il = il @ [
           Litmus_HW.CMP r;
	   Litmus_HW.BNZ lbl;
	   Litmus_HW.LBL lbl
         ]
     in
     hw_ins_of_components arch_params tid (state,il) (cs' @ cs)

(** Calculate the first unused register in a thread *)
let rec first_unused_reg n = function
  | [] -> n
  | Basic (Load((_,r),_),_) :: cs ->
     first_unused_reg (max (r+1) n) cs
  | If (_,_,cs') :: cs ->
     first_unused_reg (first_unused_reg n cs') cs
  | _ :: cs -> first_unused_reg n cs

(** [hw_thds_of_thds tid (locs,nl) thds] generates a list of hardware threads from a list [thds] of generic litmus test threads. The current thread identifier is [tid], the correspondence between locations and registers is in [locs], and [nl] is the next label to use. *)
let rec hw_thds_of_thds
          arch_params tid (loc_map, next_lbl, current_post) =
  function
  | [] -> loc_map, next_lbl, current_post, []
  | thd :: thds ->
     let next_reg = first_unused_reg 0 thd in
     let next_sentinel = 0x10 in
     let next_txid = 0 in
     let state =
       {loc_map; next_reg; next_lbl; next_sentinel;
        current_post; next_txid}
     in
     let state,il1 =
       hw_ins_of_components arch_params tid (state, []) thd
     in
     let loc_map, next_lbl, current_post, il2 =
       hw_thds_of_thds arch_params (tid+1)
         (state.loc_map, state.next_lbl, state.current_post) thds
       
     in
     loc_map, next_lbl, current_post, il1::il2

(** [hw_lit_of_lit name arch_params lt] converts the generic litmus test [lt] into a hardware litmus test, named [name], using the [arch_params.mk_fence] function to build architecture-specific fences, and using explicit status registers for store-conditionals iff the [arch_params.use_status_reg] flag is set *)
let hw_lit_of_lit name arch_params lt =
  let loc_map, _, post, thds =
    hw_thds_of_thds arch_params 0 ([], 0, lt.post) lt.thds
  in
  let locs = Assoc.group_map loc_map in
  let post = if List.exists can_fail thds then
      (Loc (-1), 1) :: post
    else
      lt.post
  in
  {Litmus_HW.name = name; locs = locs; thds = thds; post = post}
