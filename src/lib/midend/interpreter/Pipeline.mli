open CoreSyntax
(* a pipeline of mutable objects (arrays and tables) in a switch *)
type obj

(* create an array object to place in pipeline *)
val mk_array : id:Id.t -> width:int -> length:int -> pair:bool -> obj

(* create a table object *)
val mk_table : id:Id.t -> length:int -> def: (id * exp list) -> obj

(* pipeline type *)
type t

val empty : unit -> t

(* Returns a _new_ pipeline with one more stage *)
val append : t -> obj -> t

(* Reset stage counter to 0. Should be done at the beginning of each handler *)
val reset_stage : t -> unit

(* Creates a deep copy of the pipeline *)
val copy : t -> t
val length : t -> int
val to_string : ?pad:string -> t -> string

(* Updates the given stage at the given index by applying setop, and returns the
   result of getop applied to the original value. Increments stage counter. Only
   works on non-pair arrays *)
val update:
     stage:int
  -> idx:int
  -> getop:(zint -> 'a)
  -> setop:(zint -> zint)
  -> t
  -> 'a
[@@ocamlformat "disable"]

(* Same as update, but takes a complex memop, and works on either kind of array. *)
val update_complex:
     stage:int
  -> idx:int
  -> memop:(zint -> zint -> zint * zint * 'a)
  -> t
  -> 'a
[@@ocamlformat "disable"]

(* get entries from table at stage *)
val get_table_entries:
      stage:int
   -> t
   -> (id * exp list) * tbl_entry list
[@@ocamlformat "disable"]   

(* install entry into table at stage *)
val install_table_entry:
     stage: int
   -> entry: tbl_entry
   -> t
   -> unit
[@@ocamlformat "disable"]   

(* control command operations *)
val control_set:
     aname:string
  -> idx:int
  -> newvals: zint list
  -> t
  -> unit
[@@ocamlformat "disable"]

val control_setrange:
     aname:string
  -> s:int
  -> e:int
  -> newvals: zint list
  -> t
  -> unit
[@@ocamlformat "disable"]

val control_get:
     aname:string
  -> idx:int
  -> t
  -> zint list
[@@ocamlformat "disable"]

val control_getrange:
     aname:string
  -> s:int
  -> e:int
  -> t
  -> zint list list
[@@ocamlformat "disable"]
