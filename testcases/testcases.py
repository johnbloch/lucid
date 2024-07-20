from z3 import *
from ip_utils import *
from PredicateEncoding import *
from line_coverage import *
import json
import subprocess
import os
import rstr
from datetime import datetime

# next step (monday/tuesday): make predicate text input and create parser

class IP_pkt:
    def __init__(self, src_ip, dst_ip, port): 
        self.src_ip = src_ip
        self.dst_ip = dst_ip
        self.port = port
    def __repr__(self):
        return (f"(source_ip={int_to_ip(self.src_ip)}, destination_ip={int_to_ip(self.dst_ip)}, port={self.port})")

# takes a predicate (as a regular expression) and returns a list of IP_packet objects that satisfies the p[predicate]
def gen_pkt_stream(predicate, char_mapping):
    stream = []
    char_representation = rstr.xeger(predicate)
    for ch in char_representation:
        pkt = gen_pkt(char_mapping[ch])
        stream.append(pkt)
    return stream

# takes a Z3 solver object and generates a packet that satisfies the constraints
def gen_pkt(s):
    src_ip = Int('src_ip')
    dst_ip = Int('dst_ip')
    port = Int('port')
    if s.check() == sat:
        m = s.model()
        packet = IP_pkt(0 if m[src_ip] == None else m[src_ip].as_long(), 0 if m[dst_ip] == None else m[dst_ip].as_long(), 0 if m[port] == None else m[port].as_long())
        return packet
    else:
        return None

# takes a list of packet objects and file name and generates a config file that sends the packet stream
def gen_config(pkt, file_name):
    config = {}
    config["max time"] = 9999999999
    event = {}
    config["events"] = []
    event = {}
    event["name"] = "ip_pkt"
    event["args"] = [pkt.src_ip, pkt.dst_ip]
    event["locations"] = [f"0:{pkt.port}"]
    event["timestamp"] = 0
    config["events"].append(event)
    json_obj = json.dumps(config, indent=4)
    with open(file_name+".json", "w") as file:
        file.write(json_obj)

# finds the folder where the interpreter is located
def get_lucid_dir():
    curr_dir = os.getcwd()
    while True:
        if "dpt" in os.listdir(curr_dir):
            return curr_dir
        curr_dir = os.path.dirname(curr_dir)

# parses lucid program output to create list of packet objects 
def parse_lucid_output(output): 
    json_objs = [json.loads(json_obj) for json_obj in output.strip().split("\n")]
    packet_stream = []
    for json_obj in json_objs:
        pkt = IP_pkt(int(json_obj["args"][0]), int(json_obj["args"][1]), int(json_obj["locations"][0].split(":")[1]))
        packet_stream.append(pkt)
    return packet_stream
        
# runs Lucid program and returns output of switch
def run_prog(prog):
    path = os.path.join(os.getcwd(), prog) 
    r = subprocess.Popen(["./dpt", path, "-i"], stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            stdin=subprocess.PIPE, text=True, cwd=get_lucid_dir())
    stdout, stderr = r.communicate(timeout=10)
    pkt_stream = parse_lucid_output(stdout)
    return pkt_stream

# takes outputs of prog1 and prog2 and compares them using the relation specified by programmer
def validate_outputs(out1, out2, relation):
    return relation(out1, out2)

def main():
    with open('spec.py', 'r') as file:
        file_contents = file.read()

    # Evaluate the contents of the spec file
    exec(file_contents, globals())
    prog1 = globals()['prog1']
    prog2 = globals()['prog2']
    predicate = globals()['predicate']
    relation = globals()['relation']
    path_conditions = get_path_conditions(prog1 +".dpt")
    for condition in path_conditions:

        condition.push()
        condition.add(ast_to_z3(predicate))
        pkt = gen_pkt(condition)
        if pkt:
            gen_config(pkt, prog1)
            gen_config(pkt, prog2)
            out1 = run_prog(prog1+".dpt")[0]
            out2 = run_prog(prog2+".dpt")[0]
            if(not validate_outputs(out1, out2, relation)):
                print("Test Case Failed")
                print(prog1+" => " + str(out1))
                print(prog2+" => " + str(out2))
                return
                
        condition.pop()
        condition.push()
        condition.add(Not(ast_to_z3(predicate)))
        pkt = gen_pkt(condition)
        if pkt: 
            gen_config(pkt, prog1)
            gen_config(pkt, prog2)
            out1 = run_prog(prog1+".dpt")[0]
            out2 = run_prog(prog2+".dpt")[0]
            default_relation = lambda out1, out2 : out1.port == out2.port and out1.dst_ip == out2.dst_ip and out1.src_ip == out2.src_ip
            if(not validate_outputs(out1, out2, default_relation)):
                print("Test Case Failed")
                print(prog1+" => " + str(out1))
                print(prog2+" => " + str(out2))
                return
    print("Test Case Passed")
    # # 1) use z3 to find input packet that satisfies predicate
    # packet_stream = gen_pkt_stream(predicate, predicate_char_mapping)
    # # 2) create config files for prog1 and prog2 with same input packet
    # gen_config(packet_stream, prog1)
    # gen_config(packet_stream, prog2)
    
    # # # 3) read outputs of prog1 and prog2 and use relation to either pass/fail test case
    # out1 = run_prog(prog1 + ".dpt")
    # out2 = run_prog(prog2 + ".dpt")

    # if validate_outputs(out1, out2, relation):
    #     print("Test Case Passed")
    # else:
    #     print("Test Case Failed")
    # print(prog1+" => " + str(out1))
    # print(prog2+" => " + str(out2))

if __name__ == "__main__":
    startTime = datetime.now()
    main()
    # print(str((datetime.now() - startTime).total_seconds()) + " sec")

