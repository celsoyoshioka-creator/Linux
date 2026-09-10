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
import pymongo, time, random, string, concurrent.futures

MONGO_URI = "mongodb://localhost:27017/"
DB_NAME = "stress_db"
COLLECTION_NAME = "stress_col"
NUM_THREADS = 200
OPS_PER_THREAD = 500

def generate_random_string(length=50): 
    return ''.join(random.choices(string.ascii_letters + string.digits, k=length))

def worker_task(thread_id):
    client = pymongo.MongoClient(MONGO_URI)
    col = client[DB_NAME][COLLECTION_NAME]
    start_time = time.time()
    for i in range(OPS_PER_THREAD):
        col.insert_one({"thread_id": thread_id, "index": i, "payload": generate_random_string(100), "timestamp": time.time()})
        col.find_one({"thread_id": thread_id, "index": i})
    client.close()
    return time.time() - start_time

if __name__ == "__main__":
    print(f"🔥 Iniciando Stress Test no MongoDB...")
    print(f"Conexões simultâneas: {NUM_THREADS} | Inserções+Leituras por Thread: {OPS_PER_THREAD}")
    
    pymongo.MongoClient(MONGO_URI)[DB_NAME][COLLECTION_NAME].drop()
    start_global = time.time()
    
    with concurrent.futures.ThreadPoolExecutor(max_workers=NUM_THREADS) as executor:
        concurrent.futures.wait([executor.submit(worker_task, i) for i in range(NUM_THREADS)])
        
    total_time = time.time() - start_global
    total_ops = NUM_THREADS * OPS_PER_THREAD * 2
    
    print("\n✅ Teste Concluído!")
    print("=" * 40)
    print(f"Tempo total gasto:   {total_time:.2f} segundos")
    print(f"Operações Totais:    {total_ops}")
    print(f"Throughput (OPS):    {total_ops / total_time:.2f} operações por segundo")
    print("=" * 40)
EOF
./venv/bin/python stress_test.py
