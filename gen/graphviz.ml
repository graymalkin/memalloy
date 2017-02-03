(*
MIT License

Copyright (c) 2017 by John Wickerson and Tyler Sorensen.

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

open Format
open General_purpose
open Exec

(******************************)
(* Generating Graphviz output *)
(******************************)
		 
let edge_color = function
  | "co" -> "cornflowerblue"
  | "rf" -> "crimson"
  | "sb" | "ad" | "cd" | "dd" -> "black"
  | _ -> "black"
		 
let remove_transitive_edges r =
  let transitive (e,e') =
    List.exists (fun (e1,e1') ->
      List.exists (fun (e2,e2') ->
	e1 = e && e1' = e2 && e2' = e') r) r
  in
  List.filter (fun edge -> not (transitive edge)) r
		 
let remove_transitive_sb x =
  let sb = List.assoc "sb" x.rels in
  let sb = remove_transitive_edges sb in
  { x with rels = ("sb", sb) :: (remove_assocs ["sb"] x.rels) }
		 
let dot_of_event_name e =
  Str.global_replace (Str.regexp_string "$") "" e

let pp_gv_attrs oc attrs =
  pp_set oc (List.map (fun (k,v) -> sprintf "%s=\"%s\"" k v) attrs)
		     
let dot_of_event x loc_map thd_map oc e =
  let thd = List.assoc e thd_map in
  let dir,bgcolor =
    match List.mem e (get_set x "R"),
	  List.mem e (get_set x "W"),
	  List.mem e (get_set x "F")
    with
    | true, true, false -> "RMW", "plum"
    | true, false, false -> "R", "lightpink1"
    | false, true, false -> "W", "lightblue1"
    | false, false, true -> "F", "peachpuff1"
    | _ -> assert false
  in
  let attrs = get_sets x e in
  let attrs =
    List.filter (fun s -> not (List.mem s ["ev";"R";"W";"F"])) attrs
  in
  let loc =
    try sprintf "%s" (loc_of_int (List.assoc e loc_map))
    with Not_found -> ""
  in
  let gv_attrs =
    [("label", asprintf "%d:%s[%a]%s" thd dir pp_set attrs loc);
     ("shape", "box");
     ("color", "white");
     ("style", "filled");
     ("fillcolor", bgcolor)]
  in
  fprintf oc "\"%s\" [%a]\n"
	  (dot_of_event_name e) pp_gv_attrs gv_attrs

let dot_of_rel oc (name, tuples) =
  let gv_attrs =
    if List.mem name ["sb"] then [] else [("constraint", "false")]
  in
  let gv_attrs = ("fontcolor", edge_color name) :: gv_attrs in
  let gv_attrs = ("color", edge_color name) :: gv_attrs in
  let gv_attrs = ("label", name) :: gv_attrs in
  let dot_of_pair (e,e') =
    fprintf oc "%s -> %s [%a]\n"
	    (dot_of_event_name e) (dot_of_event_name e')
	    pp_gv_attrs gv_attrs
  in
  List.iter dot_of_pair tuples
  
let dot_of_execution oc x =
  let x = remove_transitive_sb x in
  let loc_map =
    find_equiv_classes (get_rel x "sloc") (get_set x "ev")
  in
  let thd_map =
    find_equiv_classes (get_rel x "sthd") (get_set x "ev")
  in
  fprintf oc "digraph G {\n";
  fprintf oc "ranksep = 1.3;\n";
  fprintf oc "nodesep = 0.8;\n";
  List.iter (dot_of_event x loc_map thd_map oc) (get_set x "ev");
  let visible_rels = remove_assocs ["sloc";"sthd"] x.rels in
  List.iter (dot_of_rel oc) visible_rels;
  fprintf oc "}\n"