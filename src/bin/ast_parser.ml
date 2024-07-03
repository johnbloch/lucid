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
        method! visit_SIf dummy e left right =
          print_string (Printing.exp_to_string e);
          print_string " (";
          self#visit_statement dummy left;
          print_string ") (";
          self#visit_statement dummy right;
          print_string ")";
      end
    in 
    v#visit_decls () ds
  in 
  get_if_nodes ds
let _ = main ()

(*

fun int get_output_port(int dst) {
    if(dst > 100){
        if(dst < 50){
            return 0;
        }else{
            return 1;
        }
    } else {
        if(dst < 150){
            return 1;
        }else{
            return 0;
        }
    }
}

==>

dst>100 (dst < 50 () ()) (dst < 150 () ())

*)