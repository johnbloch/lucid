open Dpt
open Cmdline
open Printf
open Syntax
let main () = 
  (* 1) run frontend pipeline
     2) write visitor object 
  *)
  let target_filename = Cmdline.parse () in
  Cmdline.set_dpt_file target_filename; 
  let ds = Input.parse target_filename in 
  let renaming, ds = 
    FrontendPipeline.process_prog Builtins.interp_builtin_tys ds
  in
  let get_if_nodes ds = 
    let v = 
      object (self)
        inherit [_] s_iter
        method! visit_SIf dummy _ left right =
          print_endline("Hi");
          self#visit_statement dummy left;
          self#visit_statement dummy right;
      end
    in 
    v#visit_decls () ds
  in 
  get_if_nodes ds
let _ = main ()

(*
TODO:
1) look into JSON representation of AST (using only if-else nodes for now)
2) implement Lucid program -> ast_parser.ml -> JSON AST
*)