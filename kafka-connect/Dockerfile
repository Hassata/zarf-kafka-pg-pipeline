FROM confluentinc/cp-kafka-connect:7.7.1

# JDBC-Sink-Connector
RUN confluent-hub install --no-prompt confluentinc/kafka-connect-jdbc:10.7.6

# PostgreSQL-Treiber
RUN curl -fsSL -o /usr/share/confluent-hub-components/confluentinc-kafka-connect-jdbc/lib/postgresql.jar \
    https://repo1.maven.org/maven2/org/postgresql/postgresql/42.7.4/postgresql-42.7.4.jar