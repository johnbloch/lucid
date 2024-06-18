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
predicate = r'a{3}b{3}c'
relation = lambda out1, out2: sum(1 for pkt in out1 if pkt.port == 0) == 4 and sum(1 for pkt in out2 if pkt.port == 0) == 3