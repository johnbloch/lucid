(* Main file of compiler. *)
(* open Batteries *)
open Dpt
open Consts
open BackendLogging
open LinkP4
open Printf
open IoUtils

[@@@ocaml.warning "-21"]

let report str = Console.show_message str ANSITerminal.Green "compiler"

(* minimal input
   1. dpt program
   2. P4 harness
   3. build directory *)

(* output (in build dir):
   1. P4 program (dpt + harness) -- lucid.p4
   2. switchd program -- lucid.cpp
   3. build script
   4. run sim script
   5. run hw script
   6. makefile *)

(* args parsing *)
module ArgParse = struct
  let usage = "Usage: ./dptc myProg.dpt myHarness.p4 myBuildDir"

  (*     "Usage:\n\
           \twithout p4tapp: ./dptc myProg.dpt myHarness.p4 myBuildDir\n\
           \twith p4tapp: ./dptc myProg.dpt myHarness.p4 myBuildDir [-p4tapp \
           template.p4tapp]" *)

  type args_t =
    { dptfn : string
    ; p4fn : string
    ; builddir : string
    ; use_p4tapp : bool
    ; p4tappfn : string
    ; aargs : string list
    }

  let args_default =
    { dptfn = ""
    ; p4fn = ""
    ; builddir = ""
    ; use_p4tapp = false
    ; p4tappfn = ""
    ; aargs = []
    }
  ;;

  let parse_args () =
    let args_ref = ref args_default in
    (* set named args *)
    let speclist =
      [ ( "-p4tapp"
        , Arg.String
            (fun s ->
              args_ref := { !args_ref with p4tappfn = s; use_p4tapp = true })
        , " <p4tapp template directory>" ) ]
    in
    let parse_aarg (arg : string) =
      args_ref := { !args_ref with aargs = !args_ref.aargs @ [arg] }
    in
    Arg.parse speclist parse_aarg usage;
    (* interpret positional args as named *)
    let args =
      match !args_ref.aargs with
      | [dptfn; p4fn; builddir] ->
        { !args_ref with dptfn; p4fn; builddir; aargs = [] }
      | _ -> error usage
    in
    args
  ;;
end

exception Error of string

let error s = raise (Error s)

(* todo: start all the per-module logging *)
let start_logs () = ()

(* shouldn't need to do this anymore. *)
let clear_output_dir () =
  (* clear output directory of old source. *)
  let cmd = "rm " ^ !outDir ^ "/*.dpt" in
  print_endline ("[clear_output_dir] command: " ^ cmd);
  let _ = Sys.command cmd in
  ()
;;

let dump_decls logname decls =
  print_endline ("----" ^ logname ^ "----");
  CL.iter
    (fun dec -> print_endline ("decl: " ^ LLSyntax.show_decl dec))
    decls;
  print_endline ("----" ^ logname ^ "----")
;;

let dump_decls_from_dagprog logname dagprog =
  let dmap, _, _ = dagprog in
  dump_decls logname (CL.split dmap |> snd)
;;

(**** compiler passes ****)
(* this should be the same as (most of) Main.main() *)
let cfg = Cmdline.cfg
let enable_compound_expressions = true
let do_ssa = false

(* normalize code before translating to ir. *)
let middle_passes ds =
  let cfg = { cfg with verbose = true } in
  let print_if_verbose ds =
    if cfg.verbose
    then (
      print_endline "decls: ";
      let str = Printing.decls_to_string ds in
      Console.report str)
  in
  Cmdline.cfg.verbose_types <- true;
  (* eliminate Gte and Lte *)
  let ds = EliminateEqRangeOps.transform ds in 
  (* temporary patches for incomplete features *)
  let ds = PoplPatches.eliminate_noncall_units ds in
  let ds = PoplPatches.delete_prints ds in
  (* let ds = PoplPatches.replace_ineqs ds in *)
  print_endline "------prog at start of middle passes-------";
  print_if_verbose ds;
  print_endline "------prog at start of middle passes-------";
  report "deleting unit statements that are not calls.";
  let ds = Typer.infer_prog ds in
  report "eliminating constants.";
  let ds = EliminateConsts.eliminate_consts ds in
  let ds = Typer.infer_prog ds in
  report "adding default branches.";
  let ds = AddDefaultBranches.add_default_branches ds in
  let ds = Typer.infer_prog ds in
  let ds =
    match do_ssa with
    | true ->
      let ds = SingleAssignment.transform ds in
      Typer.infer_prog ds
    | false ->
      let ds = Typer.infer_prog ds in
      report "partial SSA";
      print_endline "----------before partial SSA-----------";
      print_if_verbose ds;
      print_endline "----------before partial SSA-----------";
      let ds = PartialSingleAssignment.const_branch_vars ds in
      report "type checking after partial SSA";
      print_endline "----------after partial SSA-----------";
      print_if_verbose ds;
      print_endline "----------after partial SSA-----------";
      Typer.infer_prog ds
  in
  let ds =
    match enable_compound_expressions with
    | true ->
      (* normalize arguments *)
      let ds = PrecomputeArgs.precompute_args ds in
      (* get rid of boolean expressions *)
      let ds = EliminateBools.do_passes ds in
      (* convert integer operations into atomic exps *)
      let ds = NormalizeInts.do_passes ds in
      ds
    | false ->
      (* get rid of boolean expressions, but don't do the other
         transformations that normalize expression format. *)
      let ds = EliminateBools.do_passes ds in
      (* let ds = EliminateBools.elimination_only ds in  *)
      ds
  in
  (* give all the spans in a program unique IDs. This should be a middle pass, before translate. *)
  let ds = UniqueSpans.make_unique_spans ds in
  ds
;;

(* do a few final pre-ir setup and temporary passes *)
let final_ir_setup ds = 
  (* make sure all the event parameters have unique ids *)
  let ds = InterpHelpers.refresh_event_param_ids ds in
  (* In the body of each handler, replace parameter variables with struct instance fields. *)
  (* let ds = CL.map TranslateHandlers.rename_handler_params ds in  *)
  (* generate the control flow graph version of the program *)
  (* convert handler statement trees into operation-statement graphs *)
  OGSyntax.start_log ();
  let ds = PoplPatches.delete_casts ds in
  let opgraph_recs = CL.filter_map OGSyntax.opgraph_from_handler ds in
  ds, opgraph_recs
;;
(* translate to lucid ir *)
let to_ir ds =
  let ds, opgraph_recs = final_ir_setup ds in 
  LogIr.log_lucid "final_lucid.dpt" ds;    
  LogIr.log_lucid_osg "lucid_opstmt.dot" opgraph_recs;
  Console.report "converting to tofino instructions";
  let dag_instructions = LLTranslate.from_dpt ds opgraph_recs in
  let df_prog = DFSyntax.to_dfProg dag_instructions in
  LogIr.log_lir "initial_ir" df_prog;
  df_prog
;;
(* do optimizations on tofino ir *)
let backend_passes df_prog =
  Console.report "SALU register allocation";
  let df_prog = RegisterAllocation.merge_and_temp df_prog in
  Console.report "Control flow elimination";
  let df_prog = BranchElimination.do_passes df_prog in
  Console.report "Control flow -> Data flow";
  let dataflow_df_prog = DataFlow.do_passes df_prog in
  LogIr.log_lir "dataflow_ir" df_prog;
  Console.report "Data flow -> Pipeline";
  let pipe, straightline_prog = PipeSyntax.do_passes dataflow_df_prog in
  LogIr.log_lir_pipe "pipe_ir" pipe;
  straightline_prog
;;

(* new (3/20/21) compilation pipeline *)
let compile_to_tofino target_filename p4_harness_fn =
  start_logs ();
  (* compilation *)
  let ds = Input.parse target_filename in
  let _, ds = FrontendPipeline.process_prog ds in
  let ds = middle_passes ds in
  let dag_instructions = to_ir ds in
  let straightline_dpa_prog = backend_passes dag_instructions in
  (* P4 linking *)
  let p4_obj_dict = P4tPrint.from_straightline straightline_dpa_prog in
  let p4_str = LinkP4.link_p4 p4_obj_dict p4_harness_fn in
  (* manager code *)
  let c_str = P4tMgrPrint.c_mgr_of straightline_dpa_prog in
  let py_str = P4tMgrPrint.py_mgr_of straightline_dpa_prog in
  p4_str, c_str, py_str
;;

let main () =
  let args = ArgParse.parse_args () in
  (* setup output directory. *)
  IoUtils.setup_build_dir args.builddir;
  (* copy the source, for information, but pass the original to the compiler. *)
  (* todo: also copy the included files *)
  let _ = cpy_src_to_build args.dptfn args.builddir in
  let _ = cpy_src_to_build args.p4fn args.builddir in
  (* let args = { args with dptfn = cpy_src_to_build args.dptfn args.builddir } in
     let args = { args with p4fn = cpy_src_to_build args.p4fn args.builddir } in *)
  (* compile lucid code to P4 and C blocks *)
  let p4_str, c_str, py_str = compile_to_tofino args.dptfn args.p4fn in
  report "Compilation to P4 finished.";
  match args.use_p4tapp with
  (* generate a P4tapp project directory. note -- this currently does not emit manager code! *)
  | true ->
    GenP4tappProj.generate
      p4_str
      args.p4fn
      args.dptfn
      args.builddir
      args.p4tappfn
  (* generate a tofino app *)
  | false -> PackageTofinoApp.generate p4_str c_str py_str args.builddir
;;

let _ = main ()