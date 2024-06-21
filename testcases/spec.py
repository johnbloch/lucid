from ip_utils import *
from z3 import *
from PredicateEncoding import *

prog1 = "prog1"
prog2 = "prog2"

predicate_char_mapping = {
    "a": AndExp(IsInPrefixExp(VarExp("src_ip"), IntExp(0), IntExp(0)), AndExp(IsInPrefixExp(VarExp("dst_ip"), IntExp(0b11111100), IntExp(30)), EqExp(VarExp("port"), IntExp(0))))
}
def f(out1, out2):
    return sum(1 for pkt in out1 if pkt.port == 0) == 0 and sum(1 for pkt in out2 if pkt.port == 0) == 1

predicates = [r'a']
relations = [f]