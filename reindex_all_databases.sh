#!/bin/bash

# PostgreSQL Superuser
USER="postgres"

# Host und Port der PostgreSQL Instanz
HOST="localhost"
PORT="5432"

# Funktion zur Reindexierung einer einzelnen Datenbank
reindex_database() {
  local DB=$1

  echo "Reindexiere Datenbank: $DB"

  # Hole alle Tabellen der aktuellen Datenbank
  TABLES=$(psql -U $USER -h $HOST -p $PORT -d $DB -t -c "SELECT tablename FROM pg_tables WHERE schemaname = 'public';")

  for TABLE in $TABLES; do
    echo "Reindexiere Tabelle: $TABLE in Datenbank: $DB"

    # Hole alle Indizes der aktuellen Tabelle
    INDEXES=$(psql -U $USER -h $HOST -p $PORT -d $DB -t -c "SELECT indexname FROM pg_indexes WHERE tablename = '$TABLE';")

    for INDEX in $INDEXES; do
      echo "Reindexiere Index: $INDEX in Tabelle: $TABLE"
      psql -U $USER -h $HOST -p $PORT -d $DB -c "REINDEX INDEX CONCURRENTLY $INDEX;"
    done
  done
}

# Hole alle Datenbanknamen außer den Standarddatenbanken template0 und template1
DATABASES=$(psql -U $USER -h $HOST -p $PORT -t -c "SELECT datname FROM pg_database WHERE datname NOT IN ('template0', 'template1');")

for DB in $DATABASES; do
  reindex_database $DB
done
