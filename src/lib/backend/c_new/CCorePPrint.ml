open CCoreSyntax
let sprintf = Printf.sprintf

(* split on newlines, indent each newline by n spaces, combine back into string *)
let indent n str = str |> String.split_on_char '\n' |> List.map (fun s -> String.make n ' ' ^ s) |> String.concat "\n"

let size_to_string size = string_of_int size
let arridx_to_string = function 
  | IConst(i) -> string_of_int i
  | IVar(v) -> fst v

let func_kind_to_string = function
  | FNormal -> ""
  | FHandler -> "handler"
  | FParser -> "parser"
  | FAction -> "action"
  | FMemop -> "memop"
  | FExtern -> "extern"
;;

let id_to_string id = fst id
let cid_to_string (cid : Cid.t) = String.concat "_" (List.map id_to_string (Cid.to_ids cid))

let rec raw_ty_to_string (r: raw_ty) : string =
  match r with
  | TUnit -> "void"
  | TInt size -> "int" ^ size_to_string size
  | TBool -> "bool"
  | TRecord {labels; ts} -> 
    let label_strs = match labels with 
      | Some ids -> List.map id_to_string ids
      | None -> List.mapi (fun i _ -> "_" ^ string_of_int i) ts 
    in
    let ts_strs = List.map 
      (fun ty ->       
        let aty = alias_type ty in
        ty_to_string aty) 
      ts 
    in
    let field_strs = List.map2 (fun l e -> l ^ ": " ^ e ^";") label_strs ts_strs in
    let fields_str = String.concat " " field_strs in    
    "{" ^ fields_str ^ "}"
  | TList (ty, arridx) -> 
    ty_to_string (alias_type ty) ^ "[" ^ arridx_to_string arridx ^ "]"
  | TFun func_ty -> "function(" ^ func_ty_to_string func_ty ^ ")"
  | TBits {ternary; len} -> (if ternary then "ternary_" else "") ^ "bit[" ^ size_to_string len ^ "]"
  | TEvent -> "event"
  | TEnum list -> 
    let list_str = String.concat ", " (List.map (fun (s, i) -> id_to_string s ^ " = " ^ string_of_int i) list) in
    "enum {" ^ list_str ^ "}"
  | TBuiltin (cid, ty_list) -> 
    let ty_list_str = String.concat ", " (List.map ty_to_string ty_list) in
    cid_to_string cid ^ "<<" ^ ty_list_str ^ ">>"
  | TName cid -> cid_to_string cid
  | TAbstract (cid, ty) -> cid_to_string cid ^ " " ^ ty_to_string ty
  | TGlobal (ty) -> "global " ^ ty_to_string ty
and func_ty_to_string (f: func_ty) : string =
  let arg_tys_str = String.concat ", " (List.map ty_to_string f.arg_tys) in
  let ret_ty_str = ty_to_string f.ret_ty in
  "(" ^ arg_tys_str ^ ") -> " ^ ret_ty_str
and ty_to_string ty = raw_ty_to_string ty.raw_ty

let params_to_string params = 
  let params_str = String.concat ", " (List.map (fun (id, ty) -> id_to_string id ^ ": " ^ ty_to_string ty) params) in
  params_str
;;



let rec v_to_string (v: v) : string =
  match v with
  | VUnit -> "void"
  | VInt {value; _} -> string_of_int value
  | VBool b -> string_of_bool b
  | VRecord {labels; es} -> 
    let label_strs = match labels with 
      | Some ids -> List.map id_to_string ids
      | None -> List.mapi (fun i _ -> "_" ^ string_of_int i) es 
    in
    let es_strs = List.map value_to_string es in
    let field_strs = List.map2 (fun l e -> "." ^l ^ " = " ^ e ^";") label_strs es_strs in
    let fields_str = String.concat " " field_strs in    
    "{" ^ fields_str ^ "}"
  | VList vs -> "{" ^ String.concat ", " (List.map value_to_string vs) ^ "}"
  | VBits {ternary; bits} -> 
    let bits_str = String.concat "" (List.map (fun i -> if i = -1 then "*" else string_of_int i) bits) in
    (if ternary then "ternary " else "") ^ "bits[" ^ bits_str ^ "]"
  | VEvent e -> "event(" ^ vevent_to_string e ^ ")"
  | VSymbol (s, _) -> id_to_string s
  | VGlobal(v) -> v_to_string v.v

and vevent_to_string (e: vevent) : string =
  sprintf "%s(%s)" (cid_to_string e.evid) (String.concat ", " (List.map value_to_string e.evdata))
and value_to_string value = 
  if is_tstring value.vty then "\""^charints_to_string value^"\""
  else v_to_string value.v

let rec e_to_string (e: e) : string =
  match e with
  | EVal v -> value_to_string v
  | EVar cid -> cid_to_string cid
  | ERecord {labels; es} -> 
    let label_strs = match labels with 
      | Some ids -> List.map id_to_string ids
      | None -> List.mapi (fun i _ -> "_" ^ string_of_int i) es 
    in
    let es_strs = List.map exp_to_string es in
    let field_strs = List.map2 (fun l e -> "." ^l ^ " = " ^ e ^";") label_strs es_strs in
    let fields_str = String.concat " " field_strs in    
    "{" ^ fields_str ^ "}"
  | ECall {f; args; call_kind=CEvent} -> 
    let f_str = exp_to_string f in
    let args_str = String.concat ", " (List.map exp_to_string args) in
    f_str ^ "(" ^ args_str ^ ")"
    | ECall {f; args; _} -> 
    let f_str = exp_to_string f in
    let args_str = String.concat ", " (List.map exp_to_string args) in
    let comment_str = match (extract_func_ty f.ety) with 
      | _, _, FExtern -> " /* extern call */"
      | _ -> "" 
    in
    f_str ^ "(" ^ args_str ^ ")" ^ comment_str
  | EOp (op, args) -> op_to_string op args
  | EListGet (e, arridx) -> exp_to_string e ^ "[" ^ arridx_to_string arridx ^ "]"
and exp_to_string exp = e_to_string exp.e
and op_to_string (op: op) (args: exp list) : string =
  let args_str = List.map exp_to_string args in
  match op, args_str with
  | And, [a; b] -> a ^ " && " ^ b
  | Or, [a; b] -> a ^ " || " ^ b
  | Not, [a] -> "!" ^ a
  | Eq, [a; b] -> a ^ " == " ^ b
  | Neq, [a; b] -> a ^ " != " ^ b
  | Less, [a; b] -> a ^ " < " ^ b
  | More, [a; b] -> a ^ " > " ^ b
  | Leq, [a; b] -> a ^ " <= " ^ b
  | Geq, [a; b] -> a ^ " >= " ^ b
  | Neg, [a] -> "-" ^ a
  | Plus, [a; b] -> a ^ " + " ^ b
  | Sub, [a; b] -> a ^ " - " ^ b
  | SatPlus, [a; b] -> a ^ " |+| " ^ b
  | SatSub, [a; b] -> a ^ " |-| " ^ b
  | BitAnd, [a; b] -> a ^ " & " ^ b
  | BitOr, [a; b] -> a ^ " | " ^ b
  | BitXor, [a; b] -> a ^ " ^ " ^ b
  | BitNot, [a] -> "~" ^ a
  | LShift, [a; b] -> a ^ " << " ^ b
  | RShift, [a; b] -> a ^ " >> " ^ b
  | Slice (i, j), [a] -> a ^ "[" ^ string_of_int i ^ ":" ^ string_of_int j ^ "]"
  | PatExact, [a] -> "PatExact(" ^ a ^ ")"
  | PatMask, [a] -> "PatMask(" ^ a ^ ")"
  | Hash size, [a] -> "Hash_" ^ size_to_string size ^ "(" ^ a ^ ")"
  | Cast size, [a] ->
    let int_ty_str = raw_ty_to_string (TInt size) in
    "(" ^ int_ty_str ^ ")" ^ a
  | Conc, args -> String.concat "++" args
  | Project id, [a] when is_global (List.hd args).ety -> a ^ "->" ^ id_to_string id
  | Project id, [a]                                   -> a ^ "." ^ id_to_string id
  | Get i, [a] -> a ^ "._" ^ string_of_int i
  | _, _ -> failwith "Invalid number of arguments for operator"


let rec s_to_string (s: s) : string =
  match s with
  | SNoop -> "skip;"
  | SUnit e ->  exp_to_string e ^ ";"
  | SAssign {ids; tys; new_vars; exp} -> 
    let ids_str = String.concat ", " (List.map cid_to_string ids) in
    let exp_str = exp_to_string exp in
    (if new_vars then 
        let tys_str = String.concat ", " (List.map ty_to_string tys) in
        tys_str ^ " " ^ ids_str ^ " = " ^ exp_str ^ ";"
      else 
        ids_str ^ " = " ^ exp_str ^ ";")
  | SListSet {arr; idx; exp} -> 
    exp_to_string arr ^ "[" ^ arridx_to_string idx ^ "] = " ^ exp_to_string exp ^ ";"
  | SIf (e, s1, s2) -> 
    "if (" ^ exp_to_string e ^ ") {\n" ^ 
    indent 2 (statement_to_string s1) ^ "\n} else {\n" ^ 
    indent 2 (statement_to_string s2) ^ "\n};"
  | SMatch (e, branches) -> 
    "match (" ^ exp_to_string e ^ ") {\n" 
    ^ indent 2 (String.concat "\n" (List.map branch_to_string branches)) 
    ^ "\n}"
  | SSeq (s1, s2) -> statement_to_string s1 ^"\n" ^ statement_to_string s2
  | SRet e_opt -> 
    "return " ^ (match e_opt with 
                  | Some e -> exp_to_string e 
                  | None -> "") ^ ";"  
  | SFor{idx; bound; stmt; guard=None} -> 
    "for (" ^ (id_to_string idx) ^ " < " ^ arridx_to_string bound ^ ") {\n" ^ 
    indent 2 (statement_to_string stmt) ^ "\n}"
  | SFor{idx; bound; stmt; guard=Some(guard)} -> 
    "for (" ^ (id_to_string idx) ^ " < " ^ arridx_to_string bound ^ ") while"^(id_to_string guard)^"{\n" ^ 
    indent 2 (statement_to_string stmt) ^ "\n}"
  | SForEver(stmt) -> 
    "forever {\n" ^ indent 2 (statement_to_string stmt) ^ "\n}"

(* left off here *)
and pat_to_string (p: pat) : string =
  match p with
  | PVal v -> value_to_string v
  | PEvent {event_id; params} -> 
    let params_str = params_to_string params in
    (cid_to_string event_id) ^ "(" ^ params_str ^ ")"

and branch_to_string (b: branch) : string =
  let (pats, s) = b in
  let pats_str = String.concat " | " (List.map pat_to_string pats) in
  "case " ^ pats_str ^ ": {\n" ^ indent 2 (statement_to_string s) ^ "\n}"

and statement_to_string statement = s_to_string statement.s


let rec d_to_string (d: d) : string =
  match d with
  | DVar (id, ty, exp_opt) -> 
    let id_str = id_to_string id in
    let ty_str = ty_to_string ty in
    let exp_str = match exp_opt with 
                  | Some exp -> " = " ^ exp_to_string exp 
                  | None -> " extern" in
    if exp_opt = None then 
      "extern " ^ ty_str ^ " " ^ id_str ^ ";"
    else
      ty_str ^ " " ^ id_str ^ exp_str ^ ";"
  | DList (id, ty, exps_opt) -> 
    let id_str = id_to_string id in
    let ty_str = ty_to_string ty in
    let exps_str = match exps_opt with 
                   | Some exps -> " = [" ^ String.concat ", " (List.map exp_to_string exps) ^ "]" 
                   | None -> " extern" in
    if exps_opt = None then 
      "extern " ^ id_str ^ ": " ^ ty_str ^ ";"
    else
      id_str ^ ": " ^ ty_str ^ exps_str ^ ";"
  | DFun (kind, id, ty, params, stmt_opt) -> 
    let kind_str = func_kind_to_string kind in
    let id_str = id_to_string id in
    let ret_ty_str = match kind with 
      | FHandler -> ""
      | _ -> ty_to_string ty 
    in
    let params_str = params_to_string params in
    let stmt_str = match stmt_opt with 
                   | Some stmt -> "{\n" ^ indent 2 (statement_to_string stmt) ^ "\n}" 
                   | None -> ";" in
    if stmt_opt = None then 
      "extern " ^ kind_str ^ " " ^ ret_ty_str ^ " " ^id_str ^ "(" ^ params_str ^ ")" ^ stmt_str
    else
      kind_str ^ " "  ^ ret_ty_str ^ " " ^ id_str ^ "(" ^ params_str ^ ")" ^ stmt_str
  | DTy (cid, ty_opt) -> 
    sprintf "type %s = %s;"
      (cid_to_string cid)
      (match ty_opt with 
                 | Some ty -> ty_to_string ty 
                 | None -> " extern")
  | DEvent event_def -> 
    let id_str = id_to_string event_def.evconstrid in
    let params_str = params_to_string event_def.evparams in
    "event " ^ id_str ^ "(" ^ params_str ^ ");"

and decl_to_string decl = d_to_string decl.d


and decls_to_string decls = String.concat "\n" (List.map decl_to_string decls)