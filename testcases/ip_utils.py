from z3 import *
import rstr
# takes 8 bit ip address and converts to string representation
def int_to_ip(addr):
    return ".".join([str(int(f"{addr:08b}"[i:i+2], 2)) for i in range(0, 8, 2)])

def is_in_prefix(addr, base_addr, prefix):
    # caused error if prefix is 0:
    # bit_mask = ((1 << prefix) - 1) << (8 - prefix)
    # return True if bit_mask == 0 else addr & bit_mask == base_addr & bit_mask
    num_addrs = 2**(8-prefix)
    min_val = (base_addr >> (8 - prefix)) << (8 - prefix)
    max_val = min_val + num_addrs - 1
    return And(addr >= min_val, addr <= max_val)




    