
let compile ds = 
  (* 1. translate to core syntax *)
  let ds = SyntaxToCore.translate_prog ~preserve_user_decls:true ds in
  (* 2. run partial interpretation *)
  let ds = PartialInterpretation.interp_prog ds in
  (* 3. translate to FCore *)
  let fds = CoreToFCore.translate_prog ds in
  print_endline ("translation to FCore complete");
  FCorePrinting.decls_to_string fds 
  (* core_str *)
;;
