from ip_utils import *
from z3 import *
import re

prog1 = "prog1"
prog2 = "prog2"

src_ip = Int('src_ip')
dst_ip = Int('dst_ip')
port = Int('port')

predicate = And(is_in_prefix(src_ip, 0, 0), is_in_prefix(dst_ip, 0b11111100, 6), port == 0)
relation = lambda out1, out2: out1.port == 1 and out2.port == 0