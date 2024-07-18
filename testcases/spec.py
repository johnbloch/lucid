from ip_utils import *
from z3 import *
from PredicateEncoding import *

prog1 = "old_program"
prog2 = "new_program"

predicate = VarExp('dst_ip') ** IntExp(200)
relation = lambda out1, out2 : out1.port == 2 and out2.port == 1