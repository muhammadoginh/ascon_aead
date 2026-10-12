import sys

def parse_vcd(filename):
    signals = {
        'm': 'state',
        'd': 'round_ctr',
        '7': 'pt_valid',
        '.': 'clk',
        '$': 'pt_ready',
        '#': 'tag',
        '!': 'tag_valid'
    }
    
    current_values = {name: 'x' for name in signals.values()}
    time = 0
    
    with open(filename, 'r') as f:
        for line in f:
            line = line.strip()
            if not line:
                continue
            if line.startswith('#'):
                time = int(line[1:])
                # print values at this time step
                print(f"Time {time:8d} | clk={current_values.get('clk')} state={current_values.get('state')} round_ctr={current_values.get('round_ctr')} pt_valid={current_values.get('pt_valid')} pt_ready={current_values.get('pt_ready')}")
            elif line.startswith('b'):
                parts = line.split()
                if len(parts) == 2:
                    val = parts[0][1:] # strip 'b'
                    sig_id = parts[1]
                    if sig_id in signals:
                        current_values[signals[sig_id]] = val
            else:
                # single bit signal
                val = line[0]
                sig_id = line[1:]
                if sig_id in signals:
                    current_values[signals[sig_id]] = val

if __name__ == '__main__':
    parse_vcd('dump.vcd')
