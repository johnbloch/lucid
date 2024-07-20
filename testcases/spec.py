from ip_utils import *
from z3 import *
from PredicateEncoding import *

prog1 = "old_program"
prog2 = "new_program"
predicate = (VarExp('dst_ip') ** IntExp(200)) & (VarExp('src_ip') ** IntExp(100))
relation = lambda out : out.port == 1


