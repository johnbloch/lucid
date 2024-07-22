from ip_utils import *
from z3 import *
from PredicateEncoding import *

prog1 = "prog1"
prog2 = "prog2"
predicate = (VarExp('dst_ip') ** IntExp(50))
relation = lambda out1, out2 : out2.port == 1


