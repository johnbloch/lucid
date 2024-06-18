from ip_utils import *
from z3 import *

prog1 = "prog1"
prog2 = "prog2"

src_ip = Int('src_ip')
dst_ip = Int('dst_ip')
port = Int('port')

predicate_char_mapping = {
    "a": And(is_in_prefix(src_ip, 0b00000000, 0), is_in_prefix(dst_ip, 0b11111100, 6), port == 0),
    "b": And(is_in_prefix(src_ip, 0b00000000, 0), is_in_prefix(dst_ip, 0b00000000, 6), port == 1),
    "c": And(is_in_prefix(src_ip, 0b00000000, 0), is_in_prefix(dst_ip, 0b00000000, 0), Or(port == 0, port == 1)) 
}
relation_char_mapping = {
    "a": lambda out1, out2: out1.port == 1 and out2.port == 0,
    "b": lambda out1, out2: out1.port == 0 and out2.port == 1
}
predicates = [r'a{3}b{3}c', r'b{7}']
relations = [r'a{3}b{4}', r'b{7}']