# 1) Create the single-folder project
mkdir -p COE768_Project
cd COE768_Project

# 2) Put all four source files right here (same directory):
#    protocol.h
#    directory_server.c
#    peer_node.c
#    Makefile  (the one above)

# 3) Build the two executables in the same directory
make
# Results: ./directory_server  and  ./peer_node

# 4) Run the index server on UDP 15000 (logs will be written here)
./directory_server 15000

# 5) In a second terminal, run a peer named Bob (same directory)
./peer_node 127.0.0.1 Bob

# 6) Optional: if you prefer logs in a separate folder later:
#    mkdir logs && P2P_LOG_DIR=logs ./directory_server 15000

# 7) Clean builds if needed
make clean