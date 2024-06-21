from z3 import *
from ip_utils import *
from PredicateEncoding import *
import json
import subprocess
import os
import rstr

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

# takes a predicate (as a Z3 constraint) and generates a packet that satisfies the predicate
def gen_pkt(predicate):
    src_ip = Int('src_ip')
    dst_ip = Int('dst_ip')
    port = Int('port')
    s=Solver()
    s.add(ast_to_z3(predicate))
    if s.check() == sat:
        m = s.model()
        packet = IP_pkt(m[src_ip].as_long(), m[dst_ip].as_long(), m[port].as_long())
        return packet
    else:
        return None

# takes a list of packet objects and file name and generates a config file that sends the packet stream
def gen_config(pkt_stream, file_name):
    config = {}
    config["max time"] = 9999999999
    event = {}
    config["events"] = []
    t = 0
    for pkt in pkt_stream:
        event = {}
        event["name"] = "ip_pkt"
        event["args"] = [pkt.src_ip, pkt.dst_ip]
        event["locations"] = [f"0:{pkt.port}"]
        event["timestamp"] = t
        t += 600
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
    predicate_char_mapping = globals()['predicate_char_mapping']
    predicates = globals()['predicates']
    relations = globals()['relations']
    for i in range(len(predicates)):
        predicate, relation = predicates[i], relations[i]
        # 1) use z3 to find input packet that satisfies predicate
        packet_stream = gen_pkt_stream(predicate, predicate_char_mapping)
        # 2) create config files for prog1 and prog2 with same input packet
        gen_config(packet_stream, prog1)
        gen_config(packet_stream, prog2)
        
        # # 3) read outputs of prog1 and prog2 and use relation to either pass/fail test case
        out1 = run_prog(prog1 + ".dpt")
        out2 = run_prog(prog2 + ".dpt")

        if validate_outputs(out1, out2, relation):
            print("Test Case Passed")
        else:
            print("Test Case Failed")
        print("prog1 => " + str(out1))
        print("prog2 => " + str(out2))

if __name__ == "__main__":
    main()
