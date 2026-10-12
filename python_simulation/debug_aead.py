import sys
from ascon import ascon_initialize, ascon_process_associated_data, ascon_process_plaintext, ascon_finalize

def debug_test(key_hex, nonce_hex, ad_hex, pt_hex):
    key = bytes.fromhex(key_hex)
    nonce = bytes.fromhex(nonce_hex)
    ad = bytes.fromhex(ad_hex)
    pt = bytes.fromhex(pt_hex)
    
    S = [0, 0, 0, 0, 0]
    ascon_initialize(S, 128, 16, 12, 8, 1, key, nonce)
    print(f"After INIT: {' '.join(f'{x:016x}' for x in S)}")
    
    ascon_process_associated_data(S, 8, 16, ad)
    print(f"After AD:   {' '.join(f'{x:016x}' for x in S)}")
    
    ct = ascon_process_plaintext(S, 8, 16, pt)
    print(f"After PT:   {' '.join(f'{x:016x}' for x in S)}")
    print(f"CT:         {ct.hex()}")
    
    tag = ascon_finalize(S, 16, 12, key)
    print(f"Tag:        {tag.hex()}")

if __name__ == "__main__":
    debug_test(sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4])
