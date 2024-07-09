open Dpt
open Cmdline
open Printf
open Syntax
open Yojson.Basic

let vars = ref []
let conditions = ref []

let rec collect_vars = function
  | EVal v -> []
  | EInt(z, size) -> []
  | EVar cid -> [ String.split_on_char '~' (Cid.to_string (cid)) |> List.hd  ]
  | EOp (_, es) -> List.flatten (List.map (fun e -> collect_vars e.e) es)
  | _ -> []

let rec condition_to_smtlib = function
  | EVal v -> (
      match v.v with 
      | VInt i -> Z.to_string i.value
      | _ -> failwith "Unsupported value type"
    )
  | EInt(z, size) -> Z.to_string z
  | EVar cid -> String.split_on_char '~' (Cid.to_string cid) |> List.hd
  | EOp (op, [e]) -> (
      let operand = condition_to_smtlib e.e in
      match op with
      | Not -> Printf.sprintf "(not %s)" operand
      | _ -> failwith "Unsupported unary operator"
    )
  | EOp (op, [e1; e2]) -> (
      let left = condition_to_smtlib e1.e in
      let right = condition_to_smtlib e2.e in
      match op with
      | And -> Printf.sprintf "(and %s %s)" left right
      | Or -> Printf.sprintf "(or %s %s)" left right
      | Eq -> Printf.sprintf "(= %s %s)" left right
      | Neq -> Printf.sprintf "(not (= %s %s))" left right
      | Less -> Printf.sprintf "(< %s %s)" left right
      | Leq -> Printf.sprintf "(<= %s %s)" left right
      | More -> Printf.sprintf "(> %s %s)" left right
      | Geq -> Printf.sprintf "(>= %s %s)" left right
      | Plus -> Printf.sprintf "(+ %s %s)" left right
      | Sub -> Printf.sprintf "(- %s %s)" left right
      | _ -> failwith "Unsupported binary operator"
    )
  | _ -> failwith "Unsupported expression type"

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
          vars := (collect_vars e.e) @ !vars;
          let condition_str = Printing.exp_to_string e in
          let condition_smtlib = condition_to_smtlib e.e in
          conditions := (condition_str, condition_smtlib) :: !conditions;
          print_string (Printing.exp_to_string e);
          print_string " (";
          self#visit_statement dummy left;
          print_string ") (";
          self#visit_statement dummy right;
          print_string "), ";
      end
    in 
    v#visit_decls () ds
  in 
  get_if_nodes ds;
  (* Print all collected variables *)
  let unique_vars = List.sort_uniq String.compare !vars in
  let conditions_json = List.map (fun (cond_str, cond_smtlib) ->
    `Assoc [("condition", `String cond_str); ("smtlib", `String cond_smtlib)]
  ) !conditions in
  let json = `Assoc [("variables", `List (List.map (fun var -> `String var) unique_vars));
  ("conditions", `List conditions_json)] in
  let base_filename = Filename.remove_extension target_filename in
  let json_str = Yojson.Basic.pretty_to_string json in
  let oc = open_out (base_filename^"_conditions.json") in
  output_string oc json_str;
  close_out oc
let _ = main ()

