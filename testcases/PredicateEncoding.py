from dataclasses import dataclass
from z3 import *

@dataclass 
class Exp:
    def __and__(self, other):
        return AndExp(self, other)
    def __or__(self, other):
        return OrExp(self, other)
    def __pow__ (self, other):    
        return EqExp(self, other)
    def __mod__ (self, value):
        return IsInPrefixExp(self, value)

@dataclass
class AndExp(Exp): # logical AND
    arg1: Exp = None
    arg2: Exp = None
    __match_args__ = ("arg1", "arg2")
    def __str__(self):
        return f"({self.arg1} and {self.arg2})"

@dataclass
class OrExp(Exp): # logical OR
    arg1: Exp = None
    arg2: Exp = None
    __match_args__ = ("arg1", "arg2")
    def __str__(self):
        return f"({self.arg1} or {self.arg2})"

@dataclass
class IntExp(Exp): # integer expression (e.g. IP address, port number)
    intval: int = None
    __match_args__ = ("intval",)
    def __str__(self):
        return f"{self.intval}"

@dataclass
class VarExp(Exp): # variable expression
    varname: str = None
    __match_args__ = ("varname",)
    def __str__(self):
        return f"{self.varname}"

@dataclass 
class IPRangeExp(Exp):
    base_addr: IntExp = None
    prefix: IntExp = None
    __match_args__ = ("base_addr", "prefix")
    def __str__(self):
        return f"{self.base_addr}/{self.prefix}"

@dataclass
class IsInPrefixExp(Exp): # constraint for addr_var in given IP prefix 
    addr_var: VarExp = None
    ip_range: IPRangeExp = None
    __match_args__ = ("addr_var", "ip_range")
    def __str__(self):
        return f"{self.addr_var} in {self.ip_range}"

@dataclass
class EqExp(Exp): # equality expression
    varname: VarExp = None
    val: IntExp = None
    __match_args__ = ("varname", "val")
    def __str__(self):
        return f"({self.varname} == {self.val})"

# recursive function that converts an AST to a Z3 expression
def ast_to_z3(ast: Exp): 
    match ast:
        case AndExp(arg1, arg2):
            z3_arg1 = ast_to_z3(arg1)
            z3_arg2 = ast_to_z3(arg2)
            return And(z3_arg1, z3_arg2)
        case OrExp(arg1, arg2):
            z3_arg1 = ast_to_z3(arg1)
            z3_arg2 = ast_to_z3(arg2)
            return Or(z3_arg1, z3_arg2)
        case EqExp(varname, val):
            z3_varname = ast_to_z3(varname)
            z3_val = ast_to_z3(val)
            return z3_varname == z3_val
        case IntExp(val):
            return val
        case VarExp(varname):
            return Int(varname)
        case IsInPrefixExp(addr_var, ip_range):
            z3_addr_var = ast_to_z3(addr_var)
            z3_base_addr = ast_to_z3(ip_range.base_addr)
            z3_prefix = ast_to_z3(ip_range.prefix)
            num_addrs = 2**(32 - z3_prefix)
            min_val = (z3_base_addr >> (32 - z3_prefix)) << (32 - z3_prefix)
            max_val = min_val + num_addrs - 1
            return And(z3_addr_var >= min_val, z3_addr_var <= max_val)