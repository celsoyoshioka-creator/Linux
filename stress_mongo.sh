read -p "Qual teste de stress você quer executar? (cpu / ram / ambos) [ambos]: " STRESS_MODE && \
STRESS_MODE=${STRESS_MODE:-ambos} && \
STRESS_MODE=$(echo "$STRESS_MODE" | tr '[:upper:]' '[:lower:]') && \
sudo apt-get install -y gnupg curl python3-venv && \
curl -fsSL https://www.mongodb.org/static/pgp/server-7.0.asc | sudo gpg --yes --dearmor -o /usr/share/keyrings/mongodb-server-7.0.gpg && \
echo "deb [ arch=amd64,arm64 signed-by=/usr/share/keyrings/mongodb-server-7.0.gpg ] https://repo.mongodb.org/apt/ubuntu jammy/mongodb-org/7.0 multiverse" | sudo tee /etc/apt/sources.list.d/mongodb-org-7.0.list && \
sudo apt-get update -o Dir::Etc::sourcelist="/etc/apt/sources.list.d/mongodb-org-7.0.list" -o Dir::Etc::sourceparts="-" -o APT::Get::List-Cleanup="0" && \
sudo apt-get install -y mongodb-org && \
sudo systemctl start mongod && \
sudo systemctl enable mongod && \
mkdir -p ~/mongo_stress && cd ~/mongo_stress && \
python3 -m venv venv && \
./venv/bin/pip install pymongo && \
cat << 'EOF' > stress_test.py
import pymongo, time, random, string, concurrent.futures, sys

# Recebe o modo do bash
mode = sys.argv[1].lower() if len(sys.argv) > 1 else 'ambos'

MONGO_URI = "mongodb://localhost:27017/"
DB_NAME = "stress_db"
COLLECTION_NAME = "stress_col"
NUM_THREADS = 50

if mode == "cpu":
    OPS = 1000
    PAYLOAD_SIZE = 100 
elif mode == "ram":
    OPS = 50
    PAYLOAD_SIZE = 2 * 1024 * 1024 
else:
    mode = "ambos"
    OPS = 200
    PAYLOAD_SIZE = 1 * 1024 * 1024 

def worker_task(thread_id):
    client = pymongo.MongoClient(MONGO_URI)
    col = client[DB_NAME][COLLECTION_NAME]
    
    if mode == "cpu":
        payload = ''.join(random.choices(string.ascii_letters, k=PAYLOAD_SIZE))
    else:
        payload = "A" * PAYLOAD_SIZE 
        
    start_time = time.time()
    for i in range(OPS):
        col.insert_one({"t_id": thread_id, "idx": i, "data": payload, "ts": time.time()})
        
        if mode == "cpu":
            list(col.find({"t_id": thread_id, "data": {"$regex": ".*Z.*"}}).limit(50))
        elif mode == "ram":
            list(col.find({"t_id": thread_id}).sort("ts", -1).limit(10))
        else:
            list(col.find({"t_id": thread_id, "data": {"$regex": ".*Z.*"}}).sort("ts", -1).limit(5))
            
    client.close()
    return time.time() - start_time

if __name__ == "__main__":
    print(f"\n🔥 Iniciando Stress Test no MongoDB...")
    print(f"Modo Selecionado:    {mode.upper()}")
    print(f"Conexões simultâneas: {NUM_THREADS} | Ops/Thread: {OPS}")
    print(f"Tamanho do Documento: {PAYLOAD_SIZE / 1024:.0f} KB")
    
    pymongo.MongoClient(MONGO_URI)[DB_NAME][COLLECTION_NAME].drop()
    start_global = time.time()
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=NUM_THREADS) as executor:
        concurrent.futures.wait([executor.submit(worker_task, i) for i in range(NUM_THREADS)])
        
    total_time = time.time() - start_global
    total_ops = NUM_THREADS * OPS * 2
    
    print("\n✅ Teste Concluído!")
    print("=" * 40)
    print(f"Tempo total gasto:   {total_time:.2f} segundos")
    print(f"Operações Totais:    {total_ops}")
    print(f"Throughput (OPS):    {total_ops / total_time:.2f} operações por segundo")
    print("=" * 40)
EOF
./venv/bin/python stress_test.py "$STRESS_MODE"
