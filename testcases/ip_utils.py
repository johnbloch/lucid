# takes 8 bit ip address and converts to string representation
def int_to_ip(addr):
    return ".".join([str(int(f"{addr:032b}"[i:i+8], 2)) for i in range(0, 32, 8)])

