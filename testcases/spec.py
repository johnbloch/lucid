from ip_utils import *
from z3 import *
from PredicateEncoding import *

prog1 = "prog1"
prog2 = "prog2"

predicate_char_mapping = {
    "a": (VarExp('src_ip') % IPRangeExp(IntExp(0b11111100), IntExp(30))) & (VarExp('dst_ip') % IPRangeExp(IntExp(0b11111100), IntExp(30))) & (VarExp('port') ** IntExp(0))
}
def f(out1, out2):
    return sum(1 for pkt in out1 if pkt.port == 0) == 0 and sum(1 for pkt in out2 if pkt.port == 0) == 1

predicates = [r'a*']
relations = [f]

# ip addresses equivalent 
# get rid of disjunction? 
# line coverage 
# table action coverage 
# predicates should be automatically generated 
# capping length of stream