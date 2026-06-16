#!/usr/bin/env bash
set -euo pipefail

KAFKA_NS="${KAFKA_NS:-kafka}"
DB_NS="${DB_NS:-db}"
TOPIC="messages"
DB="messages"
DB_USER="sink"

ID="$RANDOM"
CONTENT="${*:-no-message}"

echo "▶ Sending msg id=${ID} to topic '${TOPIC}'"

# pod selection
KAFKA_POD=$(kubectl get pods -n "$KAFKA_NS" -l app.kubernetes.io/name=kafka -o jsonpath='{.items[*].metadata.name}' | awk '{print $1}')
PG_POD=$(kubectl get pods -n "$DB_NS" -l app.kubernetes.io/name=postgresql -o jsonpath='{.items[*].metadata.name}' | awk '{print $1}')
PG_PASSWORD=$(kubectl get secret -n "$DB_NS" postgresql -o jsonpath='{.data.password}' | base64 -d)

# JSON formatting 
MSG="{\"schema\":{\"type\":\"struct\",\"optional\":false,\"fields\":[{\"type\":\"int32\",\"field\":\"id\"},{\"type\":\"string\",\"field\":\"content\"}]},\"payload\":{\"id\":${ID},\"content\":\"${CONTENT}\"}}"

# Produce to Kafka
echo "$MSG" | kubectl exec -i -n "$KAFKA_NS" "$KAFKA_POD" -- \
  kafka-console-producer.sh --bootstrap-server localhost:9092 --topic "$TOPIC"

echo "▶ Polling PostgreSQL for delivery..."
for _ in $(seq 1 30); do
  ROW=$(kubectl exec -n "$DB_NS" "$PG_POD" -- env PGPASSWORD="$PG_PASSWORD" \
    psql -U "$DB_USER" -d "$DB" -tAc "SELECT content FROM ${TOPIC} WHERE id=${ID};" 2>/dev/null || true)
  
  if [ "$ROW" = "$CONTENT" ]; then
    echo "✅ E2E Success"
    echo "Message: $CONTENT"
    exit 0
  fi
  sleep 2
done

echo "❌ Timeout: Message ${ID} not found in DB."
exit 1