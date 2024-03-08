(* sanity test: how hard is it to type check CCore? *)
open Collections
open CCoreSyntax
open Batteries

exception TypeMismatch of ty * ty
exception UnboundVariable of cid
exception LengthMismatch of int * int
exception UnboundField of id
exception InvalidSize of size
exception UnboundType of cid
exception SizeMismatch of size * size
exception SelfRefSize of size
exception TypeError of string



type constr_var = 
  | IVar of string
  | IVal of int
type constr = 
  | Eq of string * constr_var


  
type env =
{
  vars : ty IdMap.t;
  tys  : ty CidMap.t;
  idx_constrs : constr list;
  ret_ty : ty option;
  (* tys  : ty CidMap.t; *)
  (* list_sizes : int option CidMap.t  *)
}
let add_var env id ty = 
  {env with vars = IdMap.add id ty env.vars}
;;
let add_vars env ids tys = 
  List.fold_left2 add_var env ids tys
;;

let add_ty env cid ty = 
  {env with tys = CidMap.add cid ty env.tys}
let add_extern_ty env cid = 
  {env with tys = CidMap.add cid textern env.tys}
let get_ty env cid = 
  match CidMap.find_opt cid env.tys with 
  | Some ty -> ty
  | None -> raise (UnboundType cid)


let add_constr env constr = 
  {env with idx_constrs = constr::env.idx_constrs}


let ty_err str = raise(TypeError(str));;

(* unify just adds constraints to context for arridxes *)

let unify_arridx env x y =
  match x, y with 
  | IConst x, IConst y -> 
    if (x = y) then env
    else ty_err "array index mismatch"
  | IConst x, IVar v 
  | IVar v , IConst x ->
    add_constr env (Eq(v, (IVal x)))
  | IVar v, IVar w -> 
    add_constr env (Eq(v, (IVar w)))
;;

let rec unify_lists env f_unify xs ys = 
  List.fold_left2 f_unify env xs ys 
;;

let rec unify_raw_ty env rawty1 rawty2 : env = 
  match rawty1, rawty2 with
  (* abstract types unify with their inner types *)
  | TAbstract(_, {raw_ty = ty1}), TAbstract(_, {raw_ty = ty2}) -> 
    unify_raw_ty env ty1 ty2
  | TAbstract(_, {raw_ty = ty1}), ty2 
  | ty1, TAbstract(_, {raw_ty = ty2}) -> 
    unify_raw_ty env ty1 ty2
  | TName cid1, TName cid2 -> 
    if (not (Cid.equal cid1 cid2)) then 
      (ty_err "named types with different names");
    (* resolve and check the types, but skip if its extern *)
    if is_textern (ty@@TName(cid1)) then env
    else 
      let ty1 = get_ty env cid1 in
      let ty2 = get_ty env cid2 in
      unify_ty env ty1 ty2
  | TUnit, TUnit -> env
  | TBool, TBool -> env
  | TEvent, TEvent -> env
  | TEnum(variants1), TEnum(variants2) -> 
      if not (List.equal (Id.equal) variants1 variants2) then 
        (raise (TypeError("enum types have different variants")));
    env
  | TBuiltin(cid1, tys1), TBuiltin(cid2, tys2) -> 
    if (not (Cid.equal cid1 cid2)) then 
      (ty_err "named types with different names");
    unify_lists env unify_ty tys1 tys2
  | TBits{ternary=t1; len=l1}, TBits{ternary=t2; len=l2} -> 
    if (t1 <> t2) then 
      (ty_err("pat type vs bitstring type"));
    if l1 <> l2 then 
      ty_err ("pat/bitstring types with different lengths");
    env
  | TInt l1, TInt l2 -> 
    if l1 <> l2 then 
      ty_err ("int types with different lengths");
    env
  | TRecord{labels=Some(l1); ts=tys1}, TRecord{labels=Some(l2); ts=tys2} -> 
    if (List.length l1 <> List.length tys1) then 
      (ty_err ("invalid record type: number of fields and types differ"));
    if (List.length l2 <> List.length tys2) then 
      (ty_err ("invalid record type: number of fields and types differ"));
    if (List.length l1 <> List.length l2) then 
      (ty_err ("record types have different numbers of fields"));
    if (not (List.for_all2 Id.equal l1 l2)) then 
      (ty_err("fields of record type are not the same"));
    if (List.length tys1 <> List.length tys2) then 
      (ty_err("record types have different numbers of types"));        
    unify_lists env unify_ty tys1 tys2      
  | TRecord{labels=None; ts=tys1}, TRecord{labels=None; ts=tys2} -> 
    if (List.length tys1 <> List.length tys2) then 
      (ty_err ("record types have different numbers types"));    
    unify_lists env unify_ty tys1 tys2      
  | TList(t1, l1), TList(t2, l2) ->
    let env' = unify_ty env t1 t2 in
    unify_arridx env' l1 l2    
  | TFun{arg_tys=arg_tys1; ret_ty=ret_ty1; func_kind=fk1}, TFun{arg_tys=arg_tys2; ret_ty=ret_ty2; func_kind=fk2} -> 
    if (fk1 <> fk2) then 
      ty_err "functions of different kinds";
    let env' = unify_lists env unify_ty arg_tys1 arg_tys2 in
    let env'' = unify_ty env' ret_ty1 ret_ty2 in
    env''
  | ( TUnit|TBool|TEvent|TInt _|TRecord _ | TName _
    |TList (_, _)|TFun _|TBits _|TEnum _|TBuiltin (_, _)), _ -> ty_err "types do not match"

and unify_ty env ty1 ty2 : env = 
  unify_raw_ty env ty1.raw_ty ty2.raw_ty
;;

(* derive the type of a value with constant sizes *)
let rec infer_value value : value = 
  let type_value value = (infer_value value).vty in 
  let ty = match value.v with 
  (* values may only have have const sizes *)
  | VUnit -> tunit ()
  | VInt{size} -> tint size 
  | VBool _ -> tbool
  | VRecord{labels=None; es} -> 
    let ts = List.map type_value es in
    ttuple ts
  | VRecord{labels=Some labels; es} ->
    let ts = List.map type_value es in
    trecord labels ts
  | VList vs -> 
    let ts = List.map type_value vs in
    tlist (List.hd ts) (IConst (List.length ts))
  | VBits{ternary; bits} -> ty@@TBits{ternary; len=sz@@List.length bits}
  | VEvent _ -> tevent
  | VEnum(_, ty) -> ty
  | VGlobal{global_ty} -> global_ty
  in
  {value with vty=ty}
;;

let rec infer_lists env f_infer xs = 
  let infer_wrapper env_outs x = 
    let (env, outs) = env_outs in
    let env, out = f_infer env x in
    env, out::outs
  in
  let env, outs = List.fold_left infer_wrapper (env, []) xs in 
  env, List.rev outs
;;

let rec infer_exp env exp : env * exp = 
  let infer_exps env = infer_lists env infer_exp in
  let env, exp = match exp.e with 
    | EVal value -> 
      let ety = (infer_value value).vty in
      env, {e=EVal(value); ety; espan=exp.espan}
    | EVar id -> 
      let ety = match IdMap.find_opt (Cid.to_id id) env.vars with
        | Some ty -> ty
        | None -> raise (UnboundVariable id)
      in
      env, {e=EVar id; ety; espan=exp.espan}
    | ERecord{labels=None; es} ->       
      let env, es' = infer_exps env es in
      let e = ERecord{labels=None; es=es'} in
      let ety = ttuple (List.map (fun exp -> exp.ety) es') in
      env, {e; ety; espan=exp.espan}
    | ERecord{labels=Some labels; es} -> 
      let env, es' = infer_exps env es in
      let e = ERecord{labels=Some(labels); es=es'} in
      let ety = ttuple (List.map (fun exp -> exp.ety) es') in
      env, {e; ety; espan=exp.espan}
    | ECall{f; call_kind=CEvent} ->
      let env, inf_f = infer_exp env f in
      if (is_tevent inf_f.ety) then unify_ty env exp.ety tevent, exp
      else ty_err "event call on non-event"
    | ECall{f; args; call_kind=CFun;} -> 
      let env, inf_f = infer_exp env f in
      let param_tys, ret_ty, _ = extract_func_ty inf_f.ety in
      let env, inf_args = infer_lists env infer_exp args in
      let arg_tys = List.map (fun exp -> exp.ety) inf_args in
      let env = unify_lists env unify_ty param_tys arg_tys in
      (* TODO: unify here isn't quite right. We 
          don't want to constrain the function's index vars, 
          just the call's. *)
      let e = ECall{f=inf_f; args=inf_args; call_kind=CFun} in
      env, {e; ety=ret_ty; espan=exp.espan}
    | EOp(op, args) -> 
      let env, op, inf_args, ety = infer_eop env op args in
      let e = EOp(op, inf_args) in
      env, {exp with e; ety}
    | EListGet(list_exp, arridx) -> 
      (* TODO *)
      let env, inf_list_exp = infer_exp env list_exp in
      if not (is_tlist inf_list_exp.ety) then 
        raise (TypeMismatch(inf_list_exp.ety, tlist inf_list_exp.ety arridx));
      let inf_ty, _ = extract_tlist inf_list_exp.ety in  
      let arr_len = match inf_ty.raw_ty with 
        | TList(_, l) -> l
        | _ -> ty_err "list get operation on not a list"
      in
      let _ = arr_len in 
      (* TODO: check arr_len against arr_idx *)
      let e = EListGet(inf_list_exp, arridx) in
      env, {exp with e; ety=inf_ty}
  in
  env, exp

(* derive the type for an operation expression *)
and infer_eop env op (args : exp list) : env * op * exp list * ty = match op, args with 
  | Not, [exp] 
  | Neg, [exp] -> (* shouldn't either not or neg be an arith/bitwise op? *)
    let env, inf_exp = infer_exp env exp in
    unify_ty env tbool inf_exp.ety, op, [inf_exp], tbool
  | And, [exp1; exp2] | Or, [exp1; exp2] ->
    let env, inf_exp1 = infer_exp env exp1 in
    let env, inf_exp2 = infer_exp env exp2 in
    let env = unify_ty env tbool inf_exp1.ety in
    let env = unify_ty env tbool inf_exp2.ety in
    env, op, [inf_exp1; inf_exp2], tbool
  | Eq, [exp1; exp2] | Neq, [exp1; exp2] -> 
    let env, inf_exp1 = infer_exp env exp1 in
    let env, inf_exp2 = infer_exp env exp2 in
    let env = unify_ty env inf_exp1.ety inf_exp2.ety in
    env, op, [inf_exp1; inf_exp2], tbool
  | Less, [exp1; exp2] | More, [exp1; exp2] | Leq , [exp1; exp2] | Geq, [exp1; exp2] 
  | Plus, [exp1; exp2] | Sub, [exp1; exp2] | SatPlus, [exp1; exp2] | SatSub, [exp1; exp2]
  | BitAnd, [exp1; exp2] | BitOr, [exp1; exp2] | BitXor, [exp1; exp2] -> 
    let env, inf_exp1 = infer_exp env exp1 in
    let env, inf_exp2 = infer_exp env exp2 in
    if (not (is_tint inf_exp1.ety)) then 
      ty_err "int op with non-int arg";
    let env = unify_ty env inf_exp1.ety inf_exp2.ety in
    env, op, [inf_exp1; inf_exp2], inf_exp1.ety
  | BitNot, [exp] -> 
    let env, inf_exp = infer_exp env exp in
    if (not (is_tint inf_exp.ety)) then 
      raise (TypeError("bitwise not on non-int"));
    env, op, [inf_exp], inf_exp.ety
  | LShift, [exp1; exp2] | RShift, [exp1; exp2] -> 
    let env, inf_exp1 = infer_exp env exp1 in
    let env, inf_exp2 = infer_exp env exp2 in
    if (not (is_tint inf_exp1.ety)) then 
      raise (TypeError("shift on non-int"));
    if (not (is_tint inf_exp2.ety)) then 
      raise (TypeError("shift by non-int"));
    let env = unify_ty env inf_exp1.ety inf_exp2.ety in
    env, op, [inf_exp1; inf_exp2], inf_exp1.ety
  | Slice(hi, lo), [exp] -> 
    let env, inf_exp = infer_exp env exp in
    if (not (is_tint inf_exp.ety)) then 
      raise (TypeError("slice on non-int"));
    let n_extracted_bits = hi - lo + 1 in
    if (n_extracted_bits <= 0) then 
      raise (TypeError("zero or negative number of bits extracted"));
    env, op, [inf_exp], tint n_extracted_bits
  | Conc, [exp1; exp2] -> 
    let env, inf_exp1 = infer_exp env exp1 in
    let env, inf_exp2 = infer_exp env exp2 in
    if (not (is_tint inf_exp1.ety)) then 
      raise (TypeError("concatenation of non-int"));
    if (not (is_tint inf_exp2.ety)) then 
      raise (TypeError("concatenation of non-int"));
    let size1 = extract_tint_size inf_exp1.ety in
    let size2 = extract_tint_size inf_exp2.ety in
    env, op, [inf_exp1; inf_exp2], tint (size1 + size2)
  | Cast(size), [exp] -> 
    let env, inf_exp = infer_exp env exp in
    if (not (is_tint inf_exp.ety)) then 
      raise (TypeError("cast of non-int"));
    env, op, [inf_exp], ty@@TInt size
  | Hash(size), _ -> 
    (* hash arguments can be anything *)
    env, op, args, ty@@TInt size
  | PatExact, [exp] -> 
    let env, inf_exp = infer_exp env exp in
    if (not (is_tint inf_exp.ety)) then 
      raise (TypeError("int-to-pat of non-int"));
    env, op, [inf_exp], tpat (extract_tint_size inf_exp.ety)
  | PatMask, [exp_val; exp_mask] -> 
    let env, inf_exp_val = infer_exp env exp_val in
    let env, inf_exp_mask = infer_exp env exp_mask in
    if (not (is_tint inf_exp_val.ety)) then 
      raise (TypeError("int-to-pat val of non-int"));
    if (not (is_tint inf_exp_mask.ety)) then 
      raise (TypeError("int-to-pat mask of non-int"));
    let env = unify_ty env inf_exp_val.ety inf_exp_mask.ety in
    env, op, [inf_exp_val; inf_exp_mask], tpat (extract_tint_size inf_exp_val.ety)
  | Project id, [exp] -> (
    let env, inf_exp = infer_exp env exp in
    if not (is_trecord inf_exp.ety) then 
      raise (TypeMismatch(inf_exp.ety, trecord [id] [inf_exp.ety]));
    let inf_labels, inf_tys = extract_trecord inf_exp.ety in
    let labels_tys = List.combine inf_labels inf_tys in
    let inf_ty = List.assoc_opt id labels_tys in
    match inf_ty with
      | Some ty -> env, op, [inf_exp], ty
      | None -> raise (UnboundField id)
  )
  | Get idx, [exp] -> (
    let env, inf_exp = infer_exp env exp in
    if not (is_ttuple inf_exp.ety) then 
      raise (TypeMismatch(inf_exp.ety, ttuple [inf_exp.ety]));
    let inf_tys = extract_ttuple inf_exp.ety in
    match (List.nth_opt inf_tys idx) with
      | Some ty -> env, op, [inf_exp], ty
      | None -> raise (UnboundField (Id.create (string_of_int idx)))
  )
  | _,_-> ty_err "error type checking Eop"
;;

let rec infer_statement env (stmt:statement) = 
  match stmt.s with 
  | SNoop -> env, stmt
  | SUnit(exp) -> 
    let env, inf_exp = infer_exp env exp in
    env, {stmt with s=SUnit(inf_exp)}
  | SAssign{ids=[id]; tys=[ty]; new_vars=true; exp} -> 
    (* declaring a new variable *)
    let env, inf_exp = infer_exp env exp in
    let env = unify_ty env ty inf_exp.ety in
    let env = add_var env (Cid.to_id id) ty in
    env, {stmt with s=SAssign{ids=[id]; tys=[ty]; new_vars=true; exp=inf_exp}}
  | SAssign{ids=[id]; new_vars=false; exp} -> 
    (* assigning to an existing variable *)
    let env, inf_exp = infer_exp env exp in
    let ty = match IdMap.find_opt (Cid.to_id id) env.vars with
      | Some ty -> ty
      | None -> raise (UnboundVariable id)
    in
    let env = unify_ty env ty inf_exp.ety in
    env, {stmt with s=SAssign{ids=[id]; tys=[ty]; new_vars=false; exp=inf_exp}}
  | SAssign{ids=ids; tys=tys; new_vars=true; exp} -> 
    (* declaring new multiple variables from a tuple-type expression *)
    let env, inf_exp = infer_exp env exp in
    if (not@@is_ttuple inf_exp.ety) then 
      raise (TypeError("only tuples can be unpacked with a multi-assign"));
    let inf_exps = flatten_tuple inf_exp in
    if (List.length ids <> List.length inf_exps) then 
      raise (LengthMismatch(List.length ids, List.length inf_exps));
    let env = unify_lists env unify_ty tys (List.map (fun exp -> exp.ety) inf_exps) in
    let env = add_vars env (List.map Cid.to_id ids) tys in
    let inf_exp = {inf_exp with e=ERecord{labels=None; es=inf_exps}} in
    env, {stmt with s=SAssign{ids=ids; tys=tys; new_vars=true; exp=inf_exp}}
  | SAssign{ids=ids; new_vars=false; exp} -> 
    (* assigning to existing multiple variables from a tuple-type expression *)
    let env, inf_exp = infer_exp env exp in
    if (not@@is_ttuple inf_exp.ety) then 
      raise (TypeError("only tuples can be unpacked with a multi-assign"));
    let inf_exps = flatten_tuple inf_exp in
    if (List.length ids <> List.length inf_exps) then 
      raise (LengthMismatch(List.length ids, List.length inf_exps));
    (* make sure all the variables are already declared in the environment *)
    let tys = List.map (fun id -> 
      match IdMap.find_opt (Cid.to_id id) env.vars with
      | Some ty -> ty
      | None -> raise (UnboundVariable id)
    ) ids in
    let env = unify_lists env unify_ty tys (List.map (fun exp -> exp.ety) inf_exps) in
    let inf_exp = {inf_exp with e=ERecord{labels=None; es=inf_exps}} in
    env, {stmt with s=SAssign{ids=ids; tys=tys; new_vars=false; exp=inf_exp}}
  | SListSet{arr; idx=arridx; exp} -> 
    let env, inf_arr = infer_exp env arr in
    let env, inf_exp = infer_exp env exp in
    if (not@@is_tlist inf_arr.ety) then 
      raise (TypeError("list set on non-list"));
    let inf_cell_ty, _ = extract_tlist inf_arr.ety in
    (* unify cell type and rhs type *)
    let env = unify_ty env inf_cell_ty inf_exp.ety in
    (* TODO: constrain |inf_arr| > arridx *)
    env, {stmt with s=SListSet{arr=inf_arr; idx=arridx; exp=inf_exp}}
  | SSeq(stmt1, stmt2) -> 
    let env, inf_stmt1 = infer_statement env stmt1 in
    let env, inf_stmt2 = infer_statement env stmt2 in
    env, {stmt with s=SSeq(inf_stmt1, inf_stmt2)}
  | SIf(econd, stmt1, stmt2) -> 
    let env, inf_econd = infer_exp env econd in
    if (not@@is_tbool inf_econd.ety) then 
      raise (TypeError("if condition must be a boolean"));
    let env, inf_stmt1 = infer_statement env stmt1 in
    let env, inf_stmt2 = infer_statement env stmt2 in
    env, {stmt with s=SIf(inf_econd, inf_stmt1, inf_stmt2)}
  | SMatch(exp, branches) -> 
    let env, inf_exp = infer_exp env exp in
    let rec infer_branches env branches =
      match branches with 
      | [] -> env, []
      | (pats, statement)::branches -> 
        let env, statement = infer_statement env statement in
        let env, rest = infer_branches env branches in
        env, (pats, statement)::rest
    in
    let env, inf_branches = infer_branches env branches in
    env, {stmt with s=SMatch(inf_exp, inf_branches)}
  | SRet(Some(exp)) -> (
    (* TODO: update environment *)
    let env, inf_exp = infer_exp env exp in
    match env.ret_ty with
    | Some ret_ty -> 
      let env = unify_ty env ret_ty inf_exp.ety in
      env, {stmt with s=SRet(Some(inf_exp))}
    | None -> 
      env, {stmt with s=SRet(Some(inf_exp))}
  )
  | SRet(None) -> env, stmt
  | SFor{idx; bound; stmt} -> 
    (* TODO: add constraint idx < bound --  only while inside of new environment? *)
    let env, inf_stmt = infer_statement env stmt in
    env, {stmt with s=SFor{idx; bound; stmt=inf_stmt}}
  | SForEver stmt -> 
    let env, inf_stmt = infer_statement env stmt in
    env, {stmt with s=SForEver(inf_stmt)}
;;

let infer_decl env decl : env * decl = 
  match decl.d with 
  | DVar(id, ty, Some(arg)) -> 
    let env, inf_arg = infer_exp env arg in
    let env = unify_ty env ty inf_arg.ety in
    let env = add_var env id ty in
    env, {decl with d=DVar(id, ty, Some(inf_arg))}
  | DVar(id, ty, None) ->
    let env = add_var env id ty in
    env, decl
  | DList(id, ty, Some(args)) -> (
    let env, inf_args = infer_lists env infer_exp args in
    match ty.raw_ty with 
      | TList(cellty, len) -> 
        (* TODO later: constrain list's length based on length of args *)
        let _ = len in
        let env = List.fold_left (fun env inf_arg -> 
          unify_ty env cellty inf_arg.ety
        ) env inf_args in
        let env = add_var env id ty in
        env, {decl with d=DList(id, ty, Some(inf_args))}
      | _ -> ty_err "list declaration with non-list type"
  )
  | DList(id, ty, None) ->
    let env = add_var env id ty in
    env, decl
  | DTy(cid, Some(ty)) -> 
    let env = add_ty env cid ty in
    env, decl
  | DTy(cid, None) ->
    let env = add_extern_ty env cid in
    env, decl
  | DEvent{evconstrid} -> 
    (* just add the event type to the var_ty table *)
    let env = add_var env evconstrid tevent in
    env, decl
  | DFun(fun_kind, id, ret_ty, params, Some(statement)) -> 
    (* set up the environment *)
    let outer_env = env in 
    let env = {env with ret_ty = None} in    
    let env = add_vars env (List.map fst params) (List.map snd params) in
    (* check the statement *)
    let env, inf_stmt = infer_statement env statement in
    (* check the return type *)
    let inf_ret_ty = match env.ret_ty with 
      | Some ty -> ty
      | None -> tunit ()
    in
    (* return to outer env *)
    let env = outer_env in
    (* unify the return type *)
    let env = unify_ty env ret_ty inf_ret_ty in
    (* update the environment with the function *)

    let fun_ty = tfun_kind fun_kind (List.map snd params) ret_ty  in
    let env = add_var env id fun_ty in
    env, {decl with d=DFun(fun_kind, id, inf_ret_ty, params, Some(inf_stmt))}
  | DFun(fun_kind, id, ret_ty, params, None) -> 
    let fun_ty = tfun_kind fun_kind (List.map snd params) ret_ty  in
    let env = add_var env id fun_ty in
    env, decl
;;
