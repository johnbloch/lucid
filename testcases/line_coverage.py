# write a script that takes prog_conditions.json and generates a list of inputs that achieves full line coverage
# 1) create a AST class with if/else nodes
# 2) parse AST field of JSON file and create tree
# 3) recurse through tree to collect constraints
# 4) solve each constraint to either find valid input or determine "dead code"
# 5) output the set of inputs


