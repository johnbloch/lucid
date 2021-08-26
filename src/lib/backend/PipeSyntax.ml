(* Extension of LLSyntax where objects 
  are laid out in a pipeline of stages. 
  Built from the DFSyntax. *)
open Consts
open LLSyntax
open DFSyntax
open SLSyntax
module MU = MergeUtils
module CL = Caml.List
open Printf
open Format
open DebugPrint
open MiscUtils

exception Error of string

let error s = raise (Error s)

(* logging *)
module DBG = BackendLogging

let outc = ref None
let dprint_endline = ref DBG.no_printf
let str_of_tid = P4tPrint.str_of_private_oid
let str_of_tids tids = CL.map str_of_tid tids |> String.concat ", "

(*** pipe syntax ***)

(* a table group is a set of tables that will be merged into one table. 
   each field corresponds to a different constraint. *)
type table_group =
  { g_tbl : decl
  ; g_acns : decl list
  ; g_alus : decl list
  ; (* the objects merged into this table group, these are just here for tracking. *)
    g_src : decl list
  }

(* a stage is a vector of tables applied in parallel. *)
type stage =
  { s_num : int
  ; (* stage number *)
    s_tgs : table_group list
  }

(* a pipe is a sequence of stages *)
type pipe =
  { p_globals : decl list
  ; (* global declarations: variables, register arrays, etc. *)
    p_stages : stage list
  }

(*** constructors ***)
let tg_ct = ref 0

let tg_next () =
  tg_ct := !tg_ct + 1;
  !tg_ct
;;

let empty_tg stage_num =
  let merged_id = tg_next () in
  let tbl_id = Cid.create_ids [Id.to_id ("merged_tbl", merged_id)] in
  let acn_id = Cid.create_ids [Id.to_id ("merged_acn", merged_id)] in
  let acn = Action (acn_id, [], []) in
  (* a rule to do nothing for any packet.*)
  let def_rule = Match (Cid.fresh ["r"], [], acn_id) in
  let tbl = Table (tbl_id, [def_rule], Some stage_num) in
  { g_tbl = tbl; g_acns = [acn]; g_alus = []; g_src = [] }
;;

let empty_stage num = { s_num = num; s_tgs = [] }
let empty_pipe = { p_globals = []; p_stages = [] }

(*** accessors ***)
let tid_of_tg tg = tid_of_tbl tg.g_tbl
let objs_of_tg tg = (tg.g_tbl :: tg.g_acns) @ tg.g_alus |> CL.rev

(* reverse order so that everything is declared before use. *)

let regs_of_tg tg =
  let reg_of_alu dec =
    match dec with
    | SInstrVec (_, {sRid=rid; _}) -> Some rid
    | _ -> None
  in
  objs_of_tg tg |> CL.filter_map reg_of_alu
;;

let hashers_of_tg tg = objs_of_tg tg |> CL.filter is_hash
let src_of_tg tg = tg.g_src

let src_tids_of_tg tg =
  tg.g_src |> dict_of_decls |> tbls_of_dmap |> CL.map id_of_decl
;;

let src_aids_of_tg tg =
  tg.g_src |> dict_of_decls |> acns_of_dmap |> CL.map id_of_decl
;;

let src_of_stage stage = CL.map src_of_tg stage.s_tgs |> CL.flatten
let src_tids_of_stage stage = CL.map src_tids_of_tg stage.s_tgs |> CL.flatten
let src_aids_of_stage stage = CL.map src_aids_of_tg stage.s_tgs |> CL.flatten
let objs_of_stage stage = CL.map objs_of_tg stage.s_tgs |> CL.flatten
let tbls_of_stage stage = CL.map (fun tg -> tg.g_tbl) stage.s_tgs

(* all the source object placed in the pipe *)
let src_of_pipe pipe = CL.map src_of_stage pipe.p_stages |> CL.flatten

let objs_of_pipe pipe =
  pipe.p_globals @ (CL.map objs_of_stage pipe.p_stages |> CL.flatten)
;;

let tbls_of_pipe pipe =
  (* staged tables *)
  CL.map tbls_of_stage pipe.p_stages |> CL.flatten
;;

(*** updates ***)

(* merge the table cid_decls[tid], and all of the actions / objects that it calls, 
into tg. return the updated table group and cid decls. This function is 
NOT AWARE OF CONSTRAINTS. *)
let merge_into_group cid_decls group tid : table_group =
  (* get the objects for tbl group and new tid *)
  let group_tid = tid_of_tg group in
  let group_decls = objs_of_tg group in
  let new_decls = objs_of_tid cid_decls tid in
  !dprint_endline "[merge_into_group] --- single-operation tables --- ";
  !dprint_endline (DebugPrint.str_of_decls new_decls);
  !dprint_endline "[merge_into_group] --- single-operation tables --- ";
  let relevant_cid_decls = group_decls @ new_decls |> dict_of_decls in
  (* do the merge *)
  let merged_cid_decls = MU.parallel_merge relevant_cid_decls group_tid tid in
  !dprint_endline "[merge_into_group] --- updated group table --- ";
  !dprint_endline
    (Cid.lookup merged_cid_decls group_tid |> DebugPrint.str_of_decl);
  !dprint_endline "[merge_into_group] --- updated group table --- ";
  (* build the merged group *)
  { (* update the table, whose rules and fields may have changed. *)
    g_tbl = Cid.lookup merged_cid_decls group_tid
  ; (* update the merged actions and objects. *)
    g_acns = acns_of_tid merged_cid_decls group_tid |> unique_list_of
  ; g_alus = alus_of_tid merged_cid_decls group_tid |> unique_list_of
  ; (* add the new source objects to the source fields. *)
    g_src = group.g_src @ new_decls
  }
;;

let merge_set_into_group cid_decls group tids : table_group =
  CL.fold_left (merge_into_group cid_decls) group tids
;;

(* merge cid_decls[tid] 
  **and all of the tables that it shares registers with** 
  into tg *)
(* turns out, this is wrong. We can't just place everything that 
uses a register the first time we see something that uses a register, 
because we might not be able to place some of the tables yet. *)
let merge_into_group_with_shared_reg_tbls cid_decls group tid =
  let regmates_of_tid = regmates_of_tid cid_decls tid in
  sprintf
    "[merge_into_group_with_shared_reg_tbls] merging %s and %i other tables \
     that share the same registers"
    (str_of_tid tid)
    (CL.length regmates_of_tid)
  |> !dprint_endline;
  CL.fold_left (merge_into_group cid_decls) group (tid :: regmates_of_tid)
;;

let add_tg s tg = { s with s_tgs = s.s_tgs @ [tg] }
let add_stage p s = { p with p_stages = p.p_stages @ [s] }

let replace_last_stage p s =
  let new_stages = s :: (CL.rev p.p_stages |> CL.tl) |> CL.rev in
  { p with p_stages = new_stages }
;;

(*** to string ***)
let summary_of_group g =
  CL.map id_of_decl g.g_src
  |> str_of_tids
  |> sprintf "<%s:[%s]>" (str_of_tids [id_of_decl g.g_tbl])
;;

let summary_of_stage s =
  sprintf "[%s]" (String.concat ", " (CL.map summary_of_group s.s_tgs))
;;

let summary_of_pipe p = String.concat "\n" (CL.map summary_of_stage p.p_stages)
let dump_pipe p = DBG.printf outc "layout:\n%s\n" (summary_of_pipe p)

let dbgstr_of_tg tg =
  let tg_str = str_of_decls ((tg.g_tbl :: tg.g_acns) @ tg.g_alus) in
  let individual_objs_str = str_of_decls (tg.g_src @ tg.g_src) in
  "----table group objects --------\n"
  ^ tg_str
  ^ "---- original objects ----\n"
  ^ individual_objs_str
;;

let dbgstr_of_stage s =
  let tgs_str = CL.map dbgstr_of_tg s.s_tgs |> String.concat "\n" in
  "---- stage ----\n"
  ^ PrintUtils.indent_block tgs_str
  ^ "---- end stage ----\n"
;;

let dbgstr_of_pipe p =
  let globals_str = str_of_decls p.p_globals in
  let pipe_str = CL.map dbgstr_of_stage p.p_stages |> String.concat "\n" in
  "---- GLOBAL OBJECTS ----\n"
  ^ globals_str
  ^ "---- STAGE OBJECTS ----\n"
  ^ pipe_str
;;

(*** constraint checking  ***)
module Constraints = struct
  (* check if tg meets table group constraints *)
  type group =
    { gmax_tbls : int
    ; gmax_regs : int
    ; gmax_hashers : int
    ; gmax_matchbits : int
    }

  let group_def =
    { gmax_tbls = 100
    ; (* there really is no limit to how many tables you can merge together. This is just here for debugging. *)
      gmax_regs = 1
    ; gmax_hashers = 1
    ; gmax_matchbits = 512
    }
  ;;

  (* check if stage meet stage constraints *)
  type stage =
    { smax_tbls : int
    ; smax_regs : int
    ; smax_hashers : int
    }

  let stage_def = { smax_tbls = 16; smax_regs = 4; smax_hashers = 6 }

  let group_check_debug cid_decls =
    !dprint_endline "--- all the decls in cid_decls before max_matchbits --- ";
    !dprint_endline (DebugPrint.str_of_decls (CL.split cid_decls |> snd));
    !dprint_endline "--- all the decls in cid_decls before max_matchbits --- ";
    !dprint_endline (show_declsMap cid_decls);
    !dprint_endline "--- all the decls in cid_decls before max_matchbits --- ";
    !dprint_endline "--- all the struct related decls --- ";
    CL.split cid_decls
    |> snd
    |> CL.filter_map (fun dec ->
           match dec with
           | StructVar _ | StructDef _ -> Some (show_decl dec)
           | _ -> None)
    |> String.concat "\n--\n"
    |> !dprint_endline
  ;;

  let group_check cid_decls tg =
    let max_tbls tg =
      let res =
        CL.length (src_tids_of_tg tg |> unique_list_of) <= group_def.gmax_tbls
      in
      if res <> true then !dprint_endline "[group_check] fail: max_tbls";
      res
    in
    let max_regs tg =
      let res =
        CL.length (regs_of_tg tg |> unique_list_of) <= group_def.gmax_regs
      in
      if res <> true then !dprint_endline "[group_check] fail: max_regs";
      res
    in
    let max_hash tg =
      let res =
        CL.length (hashers_of_tg tg |> unique_list_of) <= group_def.gmax_hashers
      in
      if res <> true then !dprint_endline "[group_check] fail: max_hash";
      res
    in
    let max_matchbits cid_decls tg =
      let keys = keys_of_table tg.g_tbl in
      let widths = CL.map (find_width_of_var cid_decls) keys in
      !dprint_endline
        ("[max_matchbits] checking table group: " ^ summary_of_group tg);
      CL.combine keys widths
      |> CL.map (fun (v, w) -> sprintf "%s: %i" (str_of_tid v) w)
      |> CL.iter (fun st -> !dprint_endline ("[max_matchbits] " ^ st));
      let total_width = CL.fold_left ( + ) 0 widths in
      !dprint_endline
        ("[max_matchbits] tg keys total_width: " ^ string_of_int total_width);
      let res = total_width <= group_def.gmax_matchbits in
      if res <> true then !dprint_endline "[group_check] fail: max_matchbits";
      res
    in
    max_tbls tg && max_regs tg && max_hash tg && max_matchbits cid_decls tg
  ;;

  (* When we place table t into a stage s, we have to make 
    sure that the dataflow constraints are still satisfied:
      1. all of tid's predecessors are already placed. 
        * this is always true because we traverse  
          the data flow graph topologically. 
      2. none of tid's predecessors appear at or after stage s.
        * we are only every attempting to place in the last stage. 
          so all we have to check is that the predecessors don't 
          appear in stage s itself. 
    *)
  let dataflow_check dfg tid prior_stages =
    (* the tables that preceed this table, according to the dfg *)
    let pred_tids = G.pred dfg tid |> unique_list_of in
    (* the tables placed in prior stages *)
    let placed_tids =
      CL.map src_tids_of_stage prior_stages |> CL.flatten |> unique_list_of
    in
    let unplaced_preds = list_sub pred_tids placed_tids in
    (* if some pred actions were not placed, fail. *)
    !dprint_endline ("[stage_check] table id: " ^ str_of_tid tid);
    !dprint_endline ("[stage_check] pred_tids: " ^ str_of_tids pred_tids);
    !dprint_endline ("[stage_check] placed_tids: " ^ str_of_tids placed_tids);
    !dprint_endline
      ("[stage_check] unplaced_preds: " ^ str_of_tids unplaced_preds);
    match unplaced_preds with
    | [] -> true
    | _ ->
      !dprint_endline "[stage_check] fail: dataflow";
      false
  ;;
  (* are all the predecessors of all the tids placed into previous stages? *)
  let dataflow_multi_check dfg tids prior_stages = 
    let single_checks = CL.map (fun tid -> dataflow_check dfg tid prior_stages) tids in 
    CL.fold_left (&&) true single_checks
  ;;

  let stage_check dfg tids stage prior_stages =
    let max_tbls stage =
      let res = CL.length (src_tids_of_stage stage) <= stage_def.smax_tbls in
      if res <> true then !dprint_endline "[stage_check] fail: max_tbls";
      res
    in
    let max_regs stage =
      let res =
        CL.length (CL.map regs_of_tg stage.s_tgs |> unique_list_of)
        <= stage_def.smax_regs
      in
      if res <> true then !dprint_endline "[stage_check] fail: max_regs";
      res
    in
    let max_hashers stage =
      let res =
        CL.length (CL.map hashers_of_tg stage.s_tgs |> unique_list_of)
        < stage_def.smax_hashers
      in
      if res <> true then !dprint_endline "[stage_check] fail: max_hashers";
      res
    in
    max_tbls stage
    && max_regs stage
    && max_hashers stage
    (* When choosing the stage, we have to 
      make sure that dataflow constraints 
      are also satisfied. *)
    && dataflow_multi_check dfg tids prior_stages
  ;;

  (* check if the entire pipe meets constraints... 
  this is just here for symmetry -- there currently are no 
  pipeline-wide constraints *)
  let pipe_check pipe =
    let _ = pipe in
    true
  ;;
end

module Placement = struct
  (* This module traverses a dataflow graph of the program in 
    topological order, placing each table node and all of its 
    action and ALU objects into the first feasible stage and table. *)
  (* Basic algorithm: 
      The basic algorithm is to try and place each atomic table (in a toplogical ordering) into the first 
      multi-operation table such that no table, stage, or dataflow constraints are violated. 
      Sometimes, it may not be possible to place a table until tables that appear 
      after it in topological ordering. For those cases, the agorithm iterates until 
      all tables are placed. 
    Optimizations: 
      The general optimization is to check as many constraints as possible before attempting to 
      place a table into a stage or table group. Most importantly, check the data flow constraints 
      before attempting to place a table into a stage. This is because placing a table into a 
      stage, then checking to see if the placement is valid, is expensive. Checking the 
      dataflow constraints is cheap. Further, for complex programs, it is much 
      more common for placement to fail because of dataflow constraints than other constraints. 
  *)


  type ctx = {
    iteration : int;
    unplaced : Cid.t list;
    placed   : (Cid.t * int) list; (* table / reg id : stage #*)
  }
  let ctx_new cid_decls = 
  { 
    iteration = 0;
    unplaced = ids_of_type is_tbl cid_decls; 
    placed = [];
  }
  ;;
  let ctx_summary ctx = 
    sprintf "[ctx_summary] iteration: %i placed: %i unplaced: %i" ctx.iteration (CL.length ctx.placed) (CL.length ctx.unplaced)
  ;;
  let ctx_note_placement stagenum ctx cid = 
    {ctx with 
      placed = (cid, stagenum)::ctx.placed;
      unplaced = list_remove ctx.unplaced cid;
    }
  ;;
  let ctx_note_placements stagenum ctx cids = 
    CL.fold_left (ctx_note_placement stagenum) ctx cids
  ;;

  (* try to place tid into tg of stage. *)
  let place_in_group (cid_decls, rebuilt_stage, tids) tg =
    match tids with
    (* there's nothing to place. *)
    | [] -> cid_decls, add_tg rebuilt_stage tg, []
    | _ ->
      (* 1. merge all tids into table group *)
      let new_tg = merge_set_into_group cid_decls tg tids in
      !dprint_endline
        ("[place_in_group] proposed table group: " ^ summary_of_group new_tg);
      !dprint_endline "[place_in_group] checking table group constraints.";
      (match Constraints.group_check cid_decls new_tg with
      (* constraint check passes -- remove all the now placed source objects, 
          add updated tg to stage, return updated cid_decls. *)
      | true ->
        !dprint_endline "[place_in_group] constraint check passed";
        let new_cid_decls = remove_decls cid_decls new_tg.g_src in
        (*             !dprint_endline ("[place_in_group] removing objects from globals: "^(CL.map id_of_decl new_tg.g_src |> P4tPrint.str_of_private_oids));
            !dprint_endline ("[place_in_group] remaining global/unplaced objects: "^(CL.split new_cid_decls |> fst |> P4tPrint.str_of_private_oids));
 *)
        new_cid_decls, add_tg rebuilt_stage new_tg, []
      (* constraint check fails -- return original versions *)
      | false ->
        !dprint_endline "[place_in_group] constraint check FAILED";
        cid_decls, add_tg rebuilt_stage tg, tids)
  ;;

  let place_in_new_group cid_decls stage tids =
    let tg = empty_tg stage.s_num in
    let cid_decls, rebuilt_stage, unplaced_tids =
      place_in_group (cid_decls, stage, tids) tg
    in
    match unplaced_tids with
    | [] -> cid_decls, rebuilt_stage
    | _ -> error "bug: a newly-created group violates group constraints"
  ;;

  (* Try to place tids into stage. 
    Return: 
            updated context
            Some update cid_decls and stage, 
            or None if it fails.  *)

  let impossible_stage_placements_skipped = ref 0 ;;
  let failed_stage_placements = ref 0 ;;

  let place_in_stage (ctx:ctx) dfg cid_decls stage prior_stages (tids:oid list) : (ctx * (declsMap * stage) option) = 
    (* optimization: before actually trying to place the table into any of the groups in this 
       stage, make sure that placement into this stage would not violate any dataflow constraints. *)
    match (Constraints.dataflow_multi_check dfg tids prior_stages) with 
    | false -> 
      !dprint_endline (sprintf "[place_in_stage] skipping attempt to place {%s} in stage %i -- dataflow constraints would be violated" (str_of_tids tids) stage.s_num);
      impossible_stage_placements_skipped := !impossible_stage_placements_skipped + 1;
      failed_stage_placements := !failed_stage_placements + 1;
      ctx, None
    (* dataflow says we can place here -- so go ahead and try it. *)
    | true -> (
      let (new_cid_decls, new_stage, unplaced_tids) = 
        CL.fold_left
          place_in_group
          (cid_decls, empty_stage stage.s_num, tids)
          stage.s_tgs
      in 
      let new_cid_decls, new_stage = match unplaced_tids with 
      | [] -> new_cid_decls, new_stage
      (* if that fails, place in a new group. We assume this always succeeds, but that's actually not true, if the 
         set of tables we're trying to place into a group are too complex for a group. That is currently an 
         un-compilable program. *)
      | _ -> let cid_decls, new_stage = place_in_new_group cid_decls stage tids in 
        cid_decls, new_stage
      in 
          (* check the stage-level constraints. *)
      match (Constraints.stage_check dfg tids new_stage prior_stages) with 
      | true -> 
        !dprint_endline ("[place_in_stage] stage constraints satisfied"); 
        (* if placement succeeded, note it in the context *)
        let new_ctx = ctx_note_placements stage.s_num ctx tids in 
        !dprint_endline ("[place_in_stage] placement of { "^(str_of_tids tids)^" } successful. "^(ctx_summary new_ctx));
        new_ctx, Some (new_cid_decls, new_stage)
      | false -> 
        failed_stage_placements := !failed_stage_placements + 1;
        !dprint_endline ("[place_in_stage] stage constraints violated"); 
        ctx, None
    )
  ;;

  (* try to put tids first stage. Recurse on tail stages if fail. *)
  let rec place_in_stages (ctx:ctx) dfg cid_decls stages prior_stages tids : (ctx * (declsMap * stage list) option) = 
    match stages with 
    | [] -> ctx, None (* ran out of stages. *)
    | stage::remaining_stages -> (
      (* try placing in first stage. *)
      let placement_result = place_in_stage ctx dfg cid_decls stage prior_stages tids in  
      match placement_result with 
      (* fail -- move stage to attempted and try next. *)
      | ctx, None -> 
        place_in_stages ctx dfg cid_decls remaining_stages (prior_stages@[stage]) tids
      (* success -- replace the stage with the new stage and prepend prior stages *)
      | updated_ctx, Some (new_cid_decls, new_stage) ->
        let num_stages = CL.length (prior_stages@[new_stage]@remaining_stages) in 
        !dprint_endline (sprintf "[place_in_stages] placed table %s in stage %i/%i" (str_of_tids tids) (CL.length prior_stages) num_stages);        
        updated_ctx, Some (new_cid_decls, prior_stages@[new_stage]@remaining_stages)
    )
  ;;

  (* extend the pipeline with a new stage and place into that stage *)
  let place_in_new_stage ctx dfg cid_decls pipe tids : (ctx * (declsMap * stage) option) = 
    let new_stage_num = CL.length pipe.p_stages in 
    !dprint_endline (sprintf "[place_in_new_stage] placed table %s in NEW stage %i" (str_of_tids tids) new_stage_num);
    place_in_stage ctx dfg cid_decls (empty_stage new_stage_num) pipe.p_stages tids 
  ;;

  (* place tids into a single group in the pipe, extending the pipe if needed. *)
  let place_in_pipe dfg (tids:Cid.t list)
      ((ctx:ctx), (cid_decls:declsMap), (p:pipe)) 
      : (ctx * declsMap * pipe) = 
      !dprint_endline ("[place_in_pipe] starting placement for: "^(str_of_tids tids));
      !dprint_endline ("[place_in_pipe] stages in current pipe: "^(CL.length p.p_stages |> string_of_int));
      match p.p_stages with 
      (* pipe is empty, add first stage. *)
      | [] -> (
        let updated_ctx, opt_res = place_in_new_stage ctx dfg cid_decls p tids in 
        let new_cid_decls, fst_stage = Option.get opt_res in 
        updated_ctx, new_cid_decls, add_stage p fst_stage
      )
      (* pipe has stages. try to place into one of them. If that fails, append a new stage. *)
      | stages -> (
          match (place_in_stages ctx dfg cid_decls stages [] tids) with
          (* placement in some existing stage succeeded. Replace the stages in the pipe. *)
          | updated_ctx, Some(new_cid_decls, new_stages) -> 
            let new_p = {p with p_stages=new_stages;} in 
            !dprint_endline ("[place_in_pipe] finished placement for: "^(str_of_tids tids));
            !dprint_endline ("[place_in_pipe] stages in updated pipe: "^(CL.length new_p.p_stages |> string_of_int));
            updated_ctx, new_cid_decls, new_p
          (* placement in an existing stage failed. 
              - try placing in a new last stage. 
              - if this fails, we cannot place the table in this round due to dataflow dependencies. *)
          | _ , None -> (
            !dprint_endline ("[place_in_pipe] placement in existing stages failed. trying a new stage for: "^(str_of_tids tids));
            match place_in_new_stage ctx dfg cid_decls p tids with 
            | updated_ctx, Some(new_cid_decls, new_last_stage) -> updated_ctx, new_cid_decls, add_stage p new_last_stage
            | _ , None -> 
              !dprint_endline ("[place_in_pipe] placement in existing or new stages failed. leaving table for next round: "^(str_of_tids tids));
              ctx, cid_decls, p
          )
      )
  ;; 

  (* place a table or register node into a single table group into the earliest 
    feasible stage of the pipeline. If no stage is feasible, try adding a new stage. 
    If that is not feasible either, return the unmodified pipeline.
      - if the node is a table that doesn't use a register, place it immediately. 
      - if the node is a table that uses a register, skip placing it. 
      - if the node is a register, place all the tables that use it. *)
  let place_node_in_pipe dfg (oid:Cid.t)
      ((ctx:ctx), (cid_decls:declsMap), (p:pipe)) 
      : (ctx * declsMap * pipe) =
    match (Cid.lookup_opt cid_decls oid) with 
    (* the object does not exist -- this can happen because there are multiple passes *)
    | None -> (ctx, cid_decls, p)
    (* case: place table *)
    | Some (Table _) -> (
      match (rids_of_tid cid_decls oid) with 
      (* the table does not use any registers, place it *)
      | [] -> place_in_pipe dfg [oid] (ctx, cid_decls, p)
      (* the table uses a register, skip placing it for now *)
      | _ -> (ctx, cid_decls, p)
    )
    (* case: place register + associated tables *)
    | Some (RegVec _) -> 
      place_in_pipe dfg (tids_of_rid cid_decls oid) (ctx, cid_decls, p)
    | Some _ -> error ("[place_node_in_pipe] attempting to place object that is not a table or register..."^(str_of_tid oid))
  ;;

  let all_placed_so_far cid_decls oid all_previous_placed =
    (not (Cid.exists cid_decls oid)) && all_previous_placed
  ;;

  let placement_complete dfg cid_decls =
    G.fold_vertex (all_placed_so_far cid_decls) dfg true
  ;;

  let unplaced_nodes dfg cid_decls pipe =
    let all_nodes = G.fold_vertex (fun v all_nodes -> v :: all_nodes) dfg [] in
    let placed_tables =
      src_of_pipe pipe |> CL.filter is_table |> CL.map id_of_decl
    in
    let unplaced_registers =
      decls_of_type is_reg cid_decls |> CL.map id_of_decl
    in
    let unplaced_nodes = list_sub all_nodes placed_tables in
    let unplaced_tables = list_sub unplaced_nodes unplaced_registers in
    !dprint_endline ("[unplaced_nodes] all_nodes: " ^ str_of_tids all_nodes);
    !dprint_endline
      ("[unplaced_nodes] placed_tables: " ^ str_of_tids placed_tables);
    !dprint_endline
      ("[unplaced_nodes] unplaced_registers: " ^ str_of_tids unplaced_registers);
    !dprint_endline
      ("[unplaced_nodes] unplaced_nodes: " ^ str_of_tids unplaced_nodes);
    !dprint_endline
      ("[unplaced_nodes] unplaced_tables: " ^ str_of_tids unplaced_tables);
    unplaced_tables
  ;;

  (* The core layout function. In each pass, the layout function 
    tries to place as many tables and registers from dfg as possible, 
    by traversing dfg topologically.  
    There are multiple passes because some programs cannot be 
    laid out in a single traversal of the DFG. This happens 
    because tables that use the same register must be placed 
    at the same time, i.e., out of order. For example, 
    consider this example: 
            (a, b)
            /    \
           /      \
          c       e
          |      /|
          |  FOO  |
          | /     |
          d ----  f 

    In the first pass, e will not be placed until FOO is visited. 
    FOO may be visited after f, in a BFS or topological ordering. 
    This will cause the placement of f to fail.  
  *)
  let rec layout_rec (ctx:ctx) cid_decls dfg pipe previously_unplaced_nodes: pipe = 
    let ctx = {ctx with iteration = (ctx.iteration + 1)} in 
    !dprint_endline ("[layout_rec] (start) "^(ctx_summary ctx));
    !dprint_endline ("[layout_rec] (start) failed_stage_placements: "^(string_of_int (!failed_stage_placements)));
    !dprint_endline ("[layout_rec] (start) impossible_stage_placements_skipped: "^(string_of_int (!impossible_stage_placements_skipped)));

    let ctx, remaining_cid_decls, updated_pipe = 
      Topo.fold 
      (place_node_in_pipe dfg)
      dfg
      (ctx, cid_decls, pipe)
    in 
    let res = match (unplaced_nodes dfg remaining_cid_decls updated_pipe) with 
    (* placement of all nodes in dfg is complete. The remaining
    objects in cid_decls are global -- build the final pipe. *)
    | [] ->
      !dprint_endline "[layout_rec] finished placing nodes in this pass.";
      { updated_pipe with p_globals = CL.split remaining_cid_decls |> snd }
    (* placement is not complete, we need to recurse on the 
    pipe that we have built and the remaining cid_decls *)
    | nodes -> (
      !dprint_endline ("[layout_rec] did not place all nodes in this pass. Remaining nodes:"^(str_of_tids nodes));
      match (list_eq previously_unplaced_nodes nodes) with 
      | true -> error ("[layout_rec] the nodes that could not be placed in the previous pass are exactly the same as the nodes that code not be placed in the current pass.")
      | false -> layout_rec ctx remaining_cid_decls dfg updated_pipe nodes
    )
    in 
    !dprint_endline ("[layout_rec] (end) "^(ctx_summary ctx));
    !dprint_endline ("[layout_rec] (end) failed_stage_placements: "^(string_of_int (!failed_stage_placements)));
    !dprint_endline ("[layout_rec] (end) impossible_stage_placements_skipped: "^(string_of_int (!impossible_stage_placements_skipped)));

    res 
  ;;

  (* convenience wrapper for recursive layout function. *)
  (* using the definitions in cid_decls, 
      generate a pipe where: 
      - every table and register node in dfg is 
      placed in a stage, along with all of the actions and alus that 
      the tables use. 
      - the other objects in cid_decls are placed as "globals" in the 
      pipe. *)
  let layout cid_decls dfg : pipe = 
    layout_rec (ctx_new cid_decls) cid_decls dfg empty_pipe []
  ;;
end 

(**** Convert to table sequence program ****)
(* This can probably be removed. We can print the pipeline directly 
  to P4, all we really need is the call sequence. *)
let rec callseq_of_tids tids : tblStmt =
  match tids with
  | [] -> Noop
  | [tid] -> CallTable tid
  | tid :: tids -> Seq (CallTable tid, callseq_of_tids tids)
;;

let tblseq_of_pipe pipe : tblSeq =
  { tsname = Consts.mergedDpName
  ; tsstmt = tbls_of_pipe pipe |> CL.map id_of_decl |> callseq_of_tids
  }
;;

let to_tblseqprog pipe : tblSeqProg =
  { tspname = Consts.progId
  ; tspglobals = Consts.globalArgs
  ; tspglobal_widths = Consts.globalArgWidths
  ; tspdecls = objs_of_pipe pipe
  ; tsptblseq = tblseq_of_pipe pipe
  }
;;

(* transform a dataflow graph, where each node represents a single-instruction 
table, into a dataflow graph that contains nodes for both tables and register arrays. 
a table has an edge to a register array iff it uses that register array *)
let to_tbl_reg_dfg cid_decls dfg =
  let add_edge src_id g dst_id = G.add_edge g src_id dst_id in
  (* for each table, get all registers. Add edges from tbl to register *)
  let add_tbl_regs (tbl_id : oid) (g : G.t) : G.t =
    (*    G.add_edge g tbl_id tbl_id *)
    let reg_ids = rids_of_tid cid_decls tbl_id in
    CL.fold_left (add_edge tbl_id) g reg_ids
  in
  let tbl_reg_dfg = G.fold_vertex add_tbl_regs dfg dfg in
  tbl_reg_dfg
;;

let do_passes df_prog =
  DBG.start_mlog __FILE__ outc dprint_endline;
  let cid_decls, _, dfg = df_prog in
  let dfg_with_regs = to_tbl_reg_dfg cid_decls dfg in
  let pipe = Placement.layout cid_decls dfg_with_regs in
  (* todo:  
            - ?? instruction dedup (salus in particular)
            - ?? huristic for traversal order -- is this necessary? *)
  let straightline_prog = to_tblseqprog pipe in
  pipe, straightline_prog
;;
