import os
import subprocess
import sys
from z3 import *
import testcases
import json

# write a script that takes prog_conditions.json and generates a list of inputs that achieves full line coverage
# 1) create a AST class with if/else nodes
# 2) parse AST field of JSON file and create tree
# 3) recurse through tree to collect constraints
# 4) solve each constraint to either find valid input or determine "dead code"
# 5) output the set of inputs

class ASTNode:
    def __init__(self, condition, if_branch=None, else_branch=None):
        self.condition = condition
        self.if_branch = if_branch
        self.else_branch = else_branch

# finds the folder where the ast parser is located
def get_astparser_dir():
    curr_dir = os.getcwd()
    while True:
        if "astparser" in os.listdir(curr_dir):
            return curr_dir
        curr_dir = os.path.dirname(curr_dir)

# run the astparser on prog
def run_astparser(prog):
    path = os.path.join(os.getcwd(), prog)
    os.chdir(get_astparser_dir())
    subprocess.run(f"./astparser {path}", shell=True, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    
# reads the string representation of program's AST
def read_ast_field(prog):
    json_filename = f"{prog.split('.')[0]}_conditions.json"
    json_path = os.path.join(os.path.dirname(__file__), json_filename)
    with open(json_path, 'r') as json_file:
        data = json.load(json_file)
    return data["AST"]

# gets the conditions in SMT-LIB  
def read_smt_mappings(prog):
    json_filename = f"{prog.split('.')[0]}_conditions.json"
    json_path = os.path.join(os.path.dirname(__file__), json_filename)
    with open(json_path, 'r') as json_file:
        data = json.load(json_file)
    return {cond["condition"]: cond["smtlib"] for cond in data["conditions"]}

# get the variables in the program
def get_variables(prog):
    json_filename = f"{prog.split('.')[0]}_conditions.json"
    json_path = os.path.join(os.path.dirname(__file__), json_filename)
    with open(json_path, 'r') as json_file:
        data = json.load(json_file)
    return data["variables"]

# convert string ast to ASTNode
def parse_ast(s):
    if not s:
        return None
    idx = 0
    while idx < len(s) and s[idx] not in ['(', ')']:
        idx += 1
    condition = s[:idx].strip()
    s = s[idx:].strip()
    # parse then 
    balance = 1
    idx = 1
    while idx < len(s) and balance > 0:
        if s[idx] == '(':
            balance += 1
        elif s[idx] == ')':
            balance -= 1
        idx += 1
    left_subtree = s[1:idx-1].strip()
    left_node = parse_ast(left_subtree)
    # parse esle
    s = s[idx:].strip()
    right_subtree = s[1:-1].strip()
    right_node = parse_ast(right_subtree)
    return ASTNode(condition, left_node, right_node)

# get all the paths from root to leaves
def collect_paths(ast, curr_path):
    if ast == None:
        yield curr_path 
        return
    yield from collect_paths(ast.if_branch, curr_path + [(ast.condition, True)])
    yield from  collect_paths(ast.else_branch, curr_path + [(ast.condition, False)])

# takes variables and list of constraints and writes to smt2 file
def generate_smt_lib(vars, constraints, prog):
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(script_dir)
    filename = prog.split(".")[0]+".smt2"
    with open(filename, 'w') as f:
        # Declare variables
        for var in vars:
            f.write(f"(declare-const {var} Int)\n")
        
        # Add constraints
        for constraint, should_be_true in constraints:
            if should_be_true:
                f.write(f"(assert {constraint})\n")
            else:
                f.write(f"(assert (not {constraint}))\n")
        
        f.write("(check-sat)\n")
        f.write("(get-model)\n")

def get_path_conditions(prog):
    run_astparser(prog)
    ast_string = read_ast_field(prog)
    ast = parse_ast(ast_string)
    paths = list(collect_paths(ast, []))
    # for path in collect_paths(ast, []):
    #     print(" ".join(f"{t}" for t in path))
    path = paths[0]
    mapping = read_smt_mappings(prog)
    vars = get_variables(prog)
    path_conditions = []
    for path in paths:
        path = [(mapping[c], b) for c, b in path]
        generate_smt_lib(vars, path, prog)
        solver = Solver()
        solver.from_file(prog.split(".")[0]+".smt2")
        path_conditions.append(solver)
        if solver.check() == sat:
            model = solver.model()
            print(model)
        else:
            print("dead code")
    return path_conditions

if __name__ == "__main__":
    get_path_conditions(sys.argv[1])
