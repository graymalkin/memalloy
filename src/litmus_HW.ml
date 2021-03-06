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

(** Representing and pretty-printing hardware litmus tests *)

open! Format
open! General_purpose

type direction = LD | ST
			     
type mem_access = {
    dir : direction; (** load or store *)
    dst : Register.t; (** destination register *)
    src : Register.t; (** source register *)
    off : Register.t option;
    (** offset register (for address dependencies) *)
    sta : Register.t option;
    (** status register (only for ARM8 exclusive stores) *)
    is_exclusive : bool;
    is_acq_rel : bool; (** for ARM8 *)
  }

(** Instruction label *)
type label = string
		     
(** Instruction in a hardware litmus test *)       
type 'fence hw_instruction =
  | Access of mem_access (** loads and stores *)
  | ADD of Register.t * Register.t * int (** addition *)
  | EOR of Register.t * Register.t * Register.t (** exclusive or *)
  | MOV of Register.t * int (** constant *)
  | HW_fence of 'fence (** memory fence *)
  | CMP of Register.t (** compare a register ... *)
  | BNZ of label (** ... and branch if it is nonzero *)
  | J of label (** unconditional branch *)
  | LBL of label (** label *)

(** Type of hardware litmus tests *)
type 'fence t = {
    name: string;
    locs: (Location.t, Register.t list) Assoc.t;
    thds: 'fence hw_instruction list list;
    post: (Litmus.address, Value.t) Assoc.t;
  }

(** Print location/register patches *)
let pp_locs pp_reg oc locs =
  fprintf oc "{\n";
  let pp_loc (x,rl) =
    let pp_patch r =
      fprintf oc "%a = %a;\n" pp_reg r Location.pp x
    in
    List.iter pp_patch rl
  in
  let ok = -1 in
  if List.mem ok (List.map fst locs) then
    fprintf oc "ok = 1;\n";
  List.iter pp_loc locs;
  fprintf oc "}\n"

(** Add thread identifier to top of each thread *)
let add_heads thds =
  let add_head n thd = sprintf "P%d" n :: thd in
  MyList.mapi add_head thds

(** Make all threads have the same length by appending no-ops *)
let add_nops longest_thd thds =
  let rec nops n = if n<=0 then [] else "" :: nops (n-1) in
  let add_nops n thd = thd @ nops (n - List.length thd + 1) in
  List.map (add_nops longest_thd) thds
	   
(** Make all instructions in a thread have the same length by appending spaces *)
let add_spaces thds =
  let longest_str l = MyList.max (List.map String.length l) in
  let rec spaces n = if n<=0 then "" else " " ^ spaces (n-1) in
  let add_spaces n s = s ^ spaces (n - String.length s) in
  let add_spaces_thd thd = List.map (add_spaces (longest_str thd)) thd in
  List.map add_spaces_thd thds

(** Print a register or a location *)
let pp_addr pp_reg oc = function
  | Litmus.Reg tr -> pp_reg oc tr
  | Litmus.Loc l -> Location.pp oc l
  
(** Print the postcondition *)
let pp_post pp_reg oc post =
  fprintf oc "exists\n";
  fprintf oc "(";
  let pp_cnstrnt oc (a,v) = fprintf oc "%a=%d" (pp_addr pp_reg) a v in
  MyList.pp_gen " /\\ " pp_cnstrnt oc post;
  fprintf oc ")\n"
	   
(** Print a hardware litmus test *)
let pp arch pp_reg pp_ins oc lt =
  fprintf oc "%s %s\n" arch lt.name;
  pp_locs pp_reg oc lt.locs;
  let thds = List.map (List.map (asprintf "%a" pp_ins)) lt.thds in
  let longest_thd = MyList.max (List.map List.length thds) in
  let thds = add_heads thds in
  let thds = add_nops longest_thd thds in
  let thds = add_spaces thds in
  for i = 0 to longest_thd do
    let line = List.map (fun thd -> List.nth thd i) thds in
    MyList.pp_gen " | " pp_str oc line;
    fprintf oc " ;\n"
  done;
  fprintf oc "\n";
  pp_post pp_reg oc lt.post
