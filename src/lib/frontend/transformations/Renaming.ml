open Batteries
open Syntax
open Collections

type kind =
  | KSize
  | KConst
  | KHandler
  | KConstr
  | KUserTy
  | KModule

module KindSet = Set.Make (struct
  type t = kind * cid

  let compare = Pervasives.compare
end)

(*** Do alpha-renaming to ensure that variable names are globally unique. Do the
    same for size names ***)

type env =
  { var_map : Cid.t CidMap.t
  ; size_map : Cid.t CidMap.t
  ; ty_map : Cid.t CidMap.t
  ; active : int (* Tells us which map to do lookups in at any given point *)
  ; module_defs : KindSet.t
  }

let empty_env =
  { var_map = CidMap.empty
  ; size_map = CidMap.empty
  ; ty_map = CidMap.empty
  ; active = 0
  ; module_defs = KindSet.empty
  }
;;

(* If env1 and env2 were generated by subsequent renamings, we can compose them
   to get a renaming from before both to after both. *)
let compose_env env1 env2 =
  let compose_maps map1 map2 =
    CidMap.fold
      (fun k v acc ->
        match CidMap.find_opt v map2 with
        | None -> acc
        | Some v' -> CidMap.add k v' acc)
      map1
      CidMap.empty
  in
  { var_map = compose_maps env1.var_map env2.var_map
  ; size_map = compose_maps env1.size_map env2.size_map
  ; ty_map = compose_maps env1.ty_map env2.ty_map
  ; active = 0
  ; module_defs = KindSet.empty
  }
;;

let compose_envs envs = List.fold_left compose_env (List.hd envs) (List.tl envs)

(* After going through a module body, add all the new definitions to the old
   environment, but with the module id as a prefix *)
let add_module_defs m_id old_env m_env =
  let prefix cid = Compound (m_id, cid) in
  let prefixed_maps =
    KindSet.fold
      (fun (k, cid) acc ->
        match k with
        | KSize ->
          let size = CidMap.find cid m_env.size_map |> prefix in
          { acc with size_map = CidMap.add (prefix cid) size acc.size_map }
        | KConstr | KConst ->
          let x = CidMap.find cid m_env.var_map |> prefix in
          { acc with var_map = CidMap.add (prefix cid) x acc.var_map }
        | KUserTy ->
          let x = CidMap.find cid m_env.ty_map |> prefix in
          { acc with ty_map = CidMap.add (prefix cid) x acc.ty_map }
        | KHandler | KModule -> acc)
      m_env.module_defs
      old_env
  in
  { prefixed_maps with
    module_defs =
      KindSet.union
        old_env.module_defs
        (KindSet.map (fun (k, id) -> k, prefix id) m_env.module_defs)
  }
;;

(* Unfortunately, scope isn't baked into the structure of our syntax the way it
   is in OCaml. This means that we need to maintain a global environment instead
   of threading it through function calls. This also means that we need to reset
   that environment at the end of each scope. A scope is created every time we
   recurse into a statement, except in SSeq. *)
let rename prog =
  let v =
    object (self)
      inherit [_] s_map as super

      val mutable env : env =
        (* Builtin stuff doesn't get renamed *)
        let open Builtins in
        let builtin_vars =
          start_id
          :: ingr_port_id
          :: this_id
          :: lucid_parse_id
          :: List.map fst Builtins.builtin_vars
          |> List.map Cid.id
        in
        let builtin_funs =
          List.map
            (fun (_, _, global_funs, constructors) ->
              let fun_cids =
                List.map
                  (fun (gf : InterpState.State.global_fun) -> gf.cid)
                  global_funs
              in
              let constructor_cids = List.map fst constructors in
              fun_cids @ constructor_cids)
            builtin_modules
          |> List.flatten
        in
        let var_map =
          List.fold_left
            (fun env cid -> CidMap.add cid cid env)
            CidMap.empty
            (builtin_vars @ builtin_funs)
        in
        let ty_map =
          List.fold_left
            (fun env (cid, _, _) -> CidMap.add cid cid env)
            CidMap.empty
            builtin_type_info
        in
        { empty_env with var_map; ty_map }

      method freshen_any active x =
        let new_x = Cid.fresh (Cid.names x) in
        (match active with
         | 0 ->
           env
             <- { env with
                  module_defs = KindSet.add (KConst, x) env.module_defs
                ; var_map = CidMap.add x new_x env.var_map
                }
         | 1 ->
           env
             <- { env with
                  module_defs = KindSet.add (KSize, x) env.module_defs
                ; size_map = CidMap.add x new_x env.size_map
                }
         | _ ->
           env
             <- { env with
                  module_defs = KindSet.add (KUserTy, x) env.module_defs
                ; ty_map = CidMap.add x new_x env.ty_map
                });
        new_x

      method freshen_var x = self#freshen_any 0 (Id x) |> Cid.to_id
      method freshen_size x = self#freshen_any 1 (Id x) |> Cid.to_id
      method freshen_ty x = self#freshen_any 2 (Id x) |> Cid.to_id

      method lookup x =
        let map =
          match env.active with
          | 0 -> env.var_map
          | 1 -> env.size_map
          | _ -> env.ty_map
        in
        match CidMap.find_opt x map with
        | Some x -> x
        | _ -> failwith @@ "Renaming: Lookup failed: " ^ Cid.to_string x

      method activate_var () = env <- { env with active = 0 }
      method activate_size () = env <- { env with active = 1 }
      method activate_ty () = env <- { env with active = 2 }

      method! visit_ty dummy ty =
        let old = env in
        self#activate_ty ();
        let ret = super#visit_ty dummy ty in
        env <- { env with active = old.active };
        ret

      method! visit_TName dummy cid sizes b =
        let old = env in
        self#activate_ty ();
        let cid = self#lookup cid in
        env <- { env with active = old.active };
        TName (cid, List.map (self#visit_size dummy) sizes, b)

      method! visit_size dummy size =
        let old = env in
        self#activate_size ();
        let ret = super#visit_size dummy size in
        env <- { env with active = old.active };
        ret

      (*** Replace variable uses. Gotta be careful not to miss any cases later
           on so we don't accidentally rewrite extra things ***)
      method! visit_id _ x = self#lookup (Id x) |> Cid.to_id
      method! visit_cid _ c = self#lookup c

      (*** Places we bind new variables ***)
      method! visit_SLocal dummy x ty e =
        let replaced_e = self#visit_exp dummy e in
        let new_ty = self#visit_ty dummy ty in
        let new_x = self#freshen_var x in
        SLocal (new_x, new_ty, replaced_e)

      method! visit_PRead dummy x ty exp =
        let new_ty = self#visit_ty dummy ty in
        let new_x = self#freshen_var x in
        let new_exp = self#visit_exp dummy exp in
        PRead (new_x, new_ty, new_exp)

        method! visit_PLocal dummy x ty exp = 
        let new_ty = self#visit_ty dummy ty in
        let new_x = self#freshen_var x in
        let new_exp = self#visit_exp dummy exp in
        PLocal (new_x, new_ty, new_exp)

      method! visit_STableMatch dummy tm =
        let tbl = self#visit_exp dummy tm.tbl in
        let keys = List.map (self#visit_exp dummy) tm.keys in
        let args = List.map (self#visit_exp dummy) tm.args in
        (* rename if the variables are declared here *)
        let outs, out_tys =
          match tm.out_tys with
          | None ->
            (* must visit outs because they have been renamed too. *)
            List.map (self#visit_id dummy) tm.outs, None
          | Some out_tys ->
            ( List.map self#freshen_var tm.outs
            , Some (List.map (self#visit_ty dummy) out_tys) )
        in
        STableMatch { tbl; keys; args; outs; out_tys }

      method! visit_body dummy (params, body) =
        let old_env = env in
        let new_params =
          List.map
            (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
            params
        in
        let new_body = self#visit_statement dummy body in
        env <- old_env;
        new_params, new_body

      (* Since many declarations have special behavior, we'll just override
         visit_d. *)
      method! visit_d dummy d =
        (* print_endline @@ "Working on:" ^ Printing.d_to_string d; *)
        match d with
        | DGlobal (x, ty, e) ->
          let replaced_ty = self#visit_ty dummy ty in
          let replaced_e = self#visit_exp dummy e in
          let new_x = self#freshen_var x in
          DGlobal (new_x, replaced_ty, replaced_e)
        | DSize (x, size) ->
          let replaced_size = Option.map (self#visit_size dummy) size in
          let new_x = self#freshen_size x in
          DSize (new_x, replaced_size)
        | DAction (x, rtys, const_params, (params, action_body)) ->
          let new_rtys = List.map (self#visit_ty dummy) rtys in
          let new_const_params =
            List.map
              (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
              const_params
          in
          let new_params =
            List.map
              (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
              params
          in
          let new_action_body = List.map (self#visit_exp dummy) action_body in
          let new_x = self#freshen_var x in
          DAction
            (new_x, new_rtys, new_const_params, (new_params, new_action_body))
        | DMemop (x, params, body) ->
          let old_env = env in
          let replaced_params =
            List.map
              (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
              params
          in
          let var_map =
            match body with
            | MBComplex body ->
              let bound_ids =
                [body.b1; body.b2]
                |> List.filter_map (fun x -> x)
                |> List.map fst
              in
              List.fold_left
                (fun acc id -> CidMap.add (Id id) (Id id) acc)
                env.var_map
                ([Builtins.cell1_id; Builtins.cell2_id] @ bound_ids)
            | _ -> env.var_map
          in
          env <- { env with var_map };
          let replaced_body = self#visit_memop_body dummy body in
          env <- old_env;
          let new_x = self#freshen_var x in
          DMemop (new_x, replaced_params, replaced_body)
        | DEvent (x, a, s, cspecs, params) ->
          let old_env = env in
          let new_params =
            List.map
              (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
              params
          in
          let new_cspecs = List.map (self#visit_constr_spec dummy) cspecs in
          env <- old_env;
          let new_x = self#freshen_var x in
          DEvent (new_x, a, s, new_cspecs, new_params)
        | DHandler (x, hsort, body) ->
          (* Note that we require events to be declared before their handler *)
          DHandler
            (self#lookup (Id x) |> Cid.to_id, hsort, self#visit_body dummy body)
        | DFun (f, rty, cspecs, (params, body)) ->
          let old_env = env in
          let new_rty = self#visit_ty dummy rty in
          let new_params =
            List.map
              (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
              params
          in
          let new_cspecs = List.map (self#visit_constr_spec dummy) cspecs in
          let new_body = self#visit_statement dummy body in
          env <- old_env;
          let new_f = self#freshen_var f in
          DFun (new_f, new_rty, new_cspecs, (new_params, new_body))
        | DConst (x, ty, exp) ->
          let new_exp = self#visit_exp dummy exp in
          let new_ty = self#visit_ty dummy ty in
          let new_x = self#freshen_var x in
          DConst (new_x, new_ty, new_exp)
        | DExtern (x, ty) ->
          let new_ty = self#visit_ty dummy ty in
          let new_x = self#freshen_var x in
          DExtern (new_x, new_ty)
        | DSymbolic (x, ty) ->
          let new_ty = self#visit_ty dummy ty in
          let new_x = self#freshen_var x in
          DSymbolic (new_x, new_ty)
        | DUserTy (id, sizes, ty) ->
          let new_sizes = List.map (self#visit_size ()) sizes in
          let new_ty = self#visit_ty () ty in
          let new_id = self#freshen_ty id in
          DUserTy (new_id, new_sizes, new_ty)
        | DConstr (id, ret_ty, params, e) ->
          let orig_env = env in
          let params =
            List.map
              (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
              params
          in
          let e = self#visit_exp dummy e in
          env <- orig_env;
          let ret_ty = self#visit_ty dummy ret_ty in
          let id = self#freshen_var id in
          DConstr (id, ret_ty, params, e)
        | DModule (id, intf, body) ->
          let orig_env = env in
          env <- { env with module_defs = KindSet.empty };
          let body = self#visit_decls dummy body in
          let intf = self#visit_interface dummy intf in
          let new_env = add_module_defs id orig_env env in
          env <- new_env;
          DModule (id, intf, body)
        | DParser (id, params, body) ->
          let orig_env = env in
          let params =
            List.map
              (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
              params
          in
          let body = self#visit_parser_block dummy body in
          env <- orig_env;
          (* don't freshen the id if it is the main parser. 
             We don't add main_parser to the builtins, because this is 
             different from a builtin. A builtin never gets "assigned" 
             in the program. However, the main parser does. *)
          let id = if (Id.equal id (Builtins.main_parse_id)) then id else self#freshen_var id in
          DParser (id, params, body)
        | DModuleAlias _ -> failwith "Should be eliminated before this"

      (*** Places we enter a scope ***)
      method! visit_SIf dummy test left right =
        let orig_env = env in
        let test' = self#visit_exp dummy test in
        let left' = self#visit_statement dummy left in
        env <- orig_env;
        let right' = self#visit_statement dummy right in
        env <- orig_env;
        SIf (test', left', right')

      method! visit_EComp dummy e i k =
        let old_env = env in
        let k = self#visit_size dummy k in
        let i = self#freshen_size i in
        let e = self#visit_exp dummy e in
        env <- old_env;
        EComp (e, i, k)

      method! visit_SLoop dummy s i k =
        let old_env = env in
        let k = self#visit_size dummy k in
        let i = self#freshen_size i in
        let s = self#visit_statement dummy s in
        env <- old_env;
        SLoop (s, i, k)

      method! visit_SMatch dummy es branches =
        let es = List.map (self#visit_exp dummy) es in
        let old_env = env in
        let branches =
          List.map
            (fun b ->
              let ret = self#visit_branch dummy b in
              env <- old_env;
              ret)
            branches
        in
        SMatch (es, branches)

      (* added for event matching *)
      method! visit_branch dummy (ps, s) = 
        let new_ps = List.map (fun p -> self#visit_pat dummy p) ps in
        let new_s = self#visit_statement dummy s in
        (new_ps, new_s)
      
      method! visit_pat dummy pat = 
        match pat with 
        | PEvent (cid, params) -> 
          (let new_params = List.map
            (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
            params in PEvent (cid, new_params))
        | _ -> super#visit_pat dummy pat      



      (*** Special Cases ***)
      method! visit_params dummy params =
        (* Don't rename parameters unless they're part of a body declaration *)
        List.map (fun (id, ty) -> id, self#visit_ty dummy ty) params

      (* Declaration-like things where we don't rename parts of them *)
      method! visit_InTy dummy id sizes tyo b =
        self#activate_ty ();
        let id = self#visit_id dummy id in
        self#activate_var ();
        let sizes = List.map (self#visit_size ()) sizes in
        let tyo = Option.map (self#visit_ty dummy) tyo in
        InTy (id, sizes, tyo, b)

      method! visit_InConstr dummy id ret_ty params =
        let id = self#visit_id dummy id in
        let ret_ty = self#visit_ty dummy ret_ty in
        let params = self#visit_params dummy params in
        InConstr (id, ret_ty, params)

      method! visit_InModule dummy id intf =
        InModule (id, self#visit_interface dummy intf)

      method! visit_InFun dummy id rty cspecs params =
        let new_id = self#visit_id dummy id in
        let old_env = env in
        let new_rty = self#visit_ty dummy rty in
        let new_params =
          List.map
            (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
            params
        in
        let new_cspecs = List.map (self#visit_constr_spec dummy) cspecs in
        env <- old_env;
        InFun (new_id, new_rty, new_cspecs, new_params)

      method! visit_InEvent dummy id cspecs params =
        let new_id = self#visit_id dummy id in
        let old_env = env in
        let new_params =
          List.map
            (fun (id, ty) -> self#freshen_var id, self#visit_ty dummy ty)
            params
        in
        let new_cspecs = List.map (self#visit_constr_spec dummy) cspecs in
        env <- old_env;
        InEvent (new_id, new_cspecs, new_params)

      method! visit_FIndex dummy id eff =
        (* Don't rename the ids here, typing takes care of that *)
        FIndex (id, self#visit_effect dummy eff)

      (* Ids that aren't variable IDs and shouldn't be renamed *)
      method! visit_TAbstract _ =
        failwith "Shouldn't encounter TAbstract during renaming"

      method! visit_exp dummy e = { e with e = self#visit_e dummy e.e }

      method! visit_TQVar dummy tqv =
        match tqv with
        | TVar { contents = Link x } -> self#visit_raw_ty dummy x
        | _ -> TQVar tqv

      method! visit_IVar dummy tqv =
        match tqv with
        | TVar { contents = Link x } -> self#visit_size dummy x
        | _ -> IVar tqv

      method! visit_FVar dummy tqv =
        match tqv with
        | TVar { contents = Link x } -> self#visit_effect dummy x
        | _ -> FVar tqv

      method rename prog =
        self#activate_var ();
        let renamed = self#visit_decls () prog in
        env, renamed
    end
  in
  v#rename prog
;;
