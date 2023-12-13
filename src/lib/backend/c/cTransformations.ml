(* Some basic transformations applied to c code. 
   In one file because they should not be complicated. 
   
  1. strip noops.
  2. put hash expressions in their own statements.
  3. number events.
*)

open CoreSyntax 

let rec unfold_stmts (st : statement) =
  match st.s with
  | SNoop -> []
  | SSeq (s1, s2) -> unfold_stmts s1 @ unfold_stmts s2
  | _ -> [st]
;;
let rec sequence_stmts lst =
  match lst with
  | [] -> snoop
  | { s = SNoop } :: tl -> sequence_stmts tl
  | [hd] -> hd
  | hd :: tl -> sseq hd (sequence_stmts tl)
;;

let rec fold_stmts (sts : statement list) : statement = sequence_stmts sts

(* noops should be removed *)
let rec strip_noops statement : statement = 
  (* turn into a list *)
  let statements = unfold_stmts statement in
  (* recurse on if and match branches *)
  let statements = List.map 
    (fun s -> match s.s with 
      | SIf (e, s1, s2) -> {s with s=SIf(e,(strip_noops s1),(strip_noops s2))}
      | SMatch (e, branches) -> {s with s=SMatch(e,(List.map (fun (p, s) -> (p, strip_noops s)) branches))}
      | _ -> s) statements in
  (* turn back into a sequence *)
  fold_stmts statements
;;

let strip_noops = 
  object inherit [_] s_map as super
  method! visit_body () (params, stmt) = 
    (params, strip_noops stmt)
  end
;;


(* precompute hash expressions in their own statement *)

let ct = ref (-1);;
let fresh_hash_id ct = 
  ct := !ct + 1;
  "hash_var_" ^ (string_of_int !ct) |> Id.create
;;

let is_hash_stmt statment = 
  match statment.s with
  | SLocal(_, _, e) 
  | SAssign(_, e) -> (
    match e.e with 
    | EHash _ -> true 
    | _ -> false)
  | _ -> false
;;
(* hash operations have to go in their own statements *)
let precompute_hash = 
  let hash_precompute_statements = ref [] in
  object inherit [_] s_map as super
  method! visit_statement () statement = 
    (* leave simple hash statements alone *)
    if (is_hash_stmt statement) 
      then (statement) 
      else (
        (* recurse on everything else and precompute *)
        let statement = super#visit_statement () statement in
        match (!hash_precompute_statements) with
        | [] -> statement
        | pre_statements -> 
          let res = fold_stmts (pre_statements @ [statement]) in
          hash_precompute_statements := [];
          res)
  (* visit expressions, pulling out hashes *)
  method! visit_exp () e = 
    match e.e with
    | EHash(_, _) ->
      let id = fresh_hash_id ct in
      let pre_stmt = slocal id e.ety e in
      let e' = {e with e=EVar (Cid.id id)} in
      hash_precompute_statements := !hash_precompute_statements @ [pre_stmt];
      e'
    | _ -> super#visit_exp () e
  end
;;

(* all events have to have a number *)
let number_events decls = 
  let used_event_nums = List.filter_map
    (fun decl -> 
      match decl.d with 
      | DEvent(_, num_opt, _, _) -> num_opt
      | _ -> None)
    decls
  in  
  let max_event_num = List.fold_left max 0 used_event_nums in
  let next_event_num = ref (max_event_num +1) in
  let fresh_event_num () = 
    next_event_num := (!next_event_num + 1);
    !next_event_num
  in
  let v = 
    object inherit [_] s_map as super
      method! visit_decl () decl = 
        match decl.d with
        | DEvent(name, None, ty, body) -> 
          let num = fresh_event_num () in
          {decl with d=DEvent(name, Some num, ty, body)}
        | _ -> super#visit_decl () decl
    end
  in
  v#visit_decls () decls
;;

let print_assoc assoc = 
  List.iter (fun (ty, id) -> 
    Printf.printf "type: %s name: %s\n"
    (CorePrinting.ty_to_string ty)
    (CorePrinting.id_to_string id))
      assoc;
;;

Cmdline.cfg.verbose_types <- true;;


let rec assoc_custom_eq eq key = function
  | [] -> None
  | (k, v) :: rest -> if eq key k then Some v else assoc_custom_eq eq key rest
;;

let assoc_ty key = assoc_custom_eq equiv_ty key;;

(* replace user-defined types with their names *)
let uninline_user_types decls = 
  (* get an assoc of user-defined types *)
  let user_ty_to_name = List.filter_map
    (fun decl -> 
      match decl.d with 
      | DUserTy(id, ty) -> Some(ty, id)
      | _ -> None)
    decls
  in
  (* For each type, if its in the user-defined type list, 
     replace it with a named type. *)
  let v = 
    object inherit [_] s_map as super
      method! visit_DUserTy () id ty = 
        DUserTy(id, ty)
      method! visit_ty () ty = 
        match (assoc_ty ty user_ty_to_name) with 
        | None -> ty
        | Some(ty_id) -> CoreSyntax.ty (TName(Cid.id ty_id, [], false))
      end
  in
  v#visit_decls () decls
;;


let transform decls = 
  let decls = strip_noops#visit_decls () decls in
  let decls = precompute_hash#visit_decls () decls in
  let decls = number_events decls in
  let decls = uninline_user_types decls in
  decls