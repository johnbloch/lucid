(* initial C backend, for compiling function programs *)
open BackendLogging

let print_if_debug str = if Cmdline.cfg.debug then Console.report str ;;

let report_if_verbose str = 
  if (Cmdline.cfg.verbose)
    then Console.show_message str ANSITerminal.Green "C backend"
;;

let print_pause = false ;;
let printprog_if_debug ds =
  if (Cmdline.cfg.debug)
    then 
      print_endline (CorePrinting.decls_to_string ds);
      if (print_pause)
        then (
          print_endline "[debug] press enter key to continue";
          ignore (read_line ())
        )
;;

let compile ds =  
  report_if_verbose "-------Translating to Midend IR---------";
  let ds = SyntaxToCore.translate_prog ds in
  printprog_if_debug ds;
  let ds = CTransformations.strip_noops#visit_decls () ds in
  report_if_verbose "-------Translating to C---------";
  let c_str = CTranslate.translate_decls ds in
  let c_str = (CLibs.libs ["base"]) ^ "\n" ^ c_str in
  c_str
;;
