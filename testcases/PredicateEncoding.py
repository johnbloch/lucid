from dataclasses import dataclass
from z3 import *

@dataclass 
class Exp:
    pass

@dataclass
class AndExp(Exp): # logical AND
    arg1: Exp = None
    arg2: Exp = None
    __match_args__ = ("arg1", "arg2")

@dataclass
class OrExp(Exp): # logical OR
    arg1: Exp = None
    arg2: Exp = None
    __match_args__ = ("arg1", "arg2")

@dataclass
class IntExp(Exp): # integer expression (e.g. IP address, port number)
    intval: int = None
    __match_args__ = ("intval",)

@dataclass
class VarExp(Exp): # variable expression
    varname: str = None
    __match_args__ = ("varname",)

@dataclass
class IsInPrefixExp(Exp): # constraint for addr_var in given IP prefix 
    addr_var: VarExp = None
    base_addr: IntExp = None
    prefix: IntExp = None
    __match_args__ = ("addr_var", "base_addr", "prefix")

@dataclass 
class LTEExp(Exp): # less than or equal to expression
    varname: VarExp = None
    val: IntExp = None
    __match_args__ = ("varname", "val")

@dataclass 
class GTEExp(Exp): # greater than or equal to expression
    varname: VarExp = None
    val: IntExp = None
    __match_args__ = ("varname", "val")

@dataclass
class EqExp(Exp): # equality expression
    varname: VarExp = None
    val: IntExp = None
    __match_args__ = ("varname", "val")

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
        case LTEExp(varname, val):
            z3_varname = ast_to_z3(varname)
            z3_val = ast_to_z3(val)
            return z3_varname <= z3_val
        case GTEExp(varname, val):
            z3_varname = ast_to_z3(varname)
            z3_val = ast_to_z3(val)
            return z3_varname >= z3_val
        case EqExp(varname, val):
            z3_varname = ast_to_z3(varname)
            z3_val = ast_to_z3(val)
            return z3_varname == z3_val
        case IntExp(val):
            return val
        case VarExp(varname):
            return Int(varname)
        case IsInPrefixExp(addr_var, base_addr, prefix):
            z3_base_addr = ast_to_z3(base_addr)
            z3_prefix = ast_to_z3(prefix)
            num_addrs = 2**(32-z3_prefix)
            min_val = (z3_base_addr >> (32 - z3_prefix)) << (32 - z3_prefix)
            max_val = IntExp(min_val + num_addrs - 1)
            min_val = IntExp(min_val)
            return And(ast_to_z3(LTEExp(addr_var, max_val)), ast_to_z3(GTEExp(addr_var, min_val)))

