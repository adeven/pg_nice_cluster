require "pg"
require 'trollop'

module PgNiceCluster
    class Optimizer


        attr_accessor :tables, :conn, :opts, :total_size, :lower_limit

        def initialize
            @opts = Trollop::options do
                opt :db, "database name", :type => :string
                opt :user, "user name", :type => :string, :default => "postgres"
                opt :pass, "password", :type => :string
                opt :host, "host name", :type => :string, :default => "localhost"
                opt :prefix, "prefix for the temporary tables and indexes (default 'cluster_')", :type => :string, :default => "cluster"
                opt :minsize, "cut off size for small tables in mb", :default => 100
                opt :table, "table name if only one table should be clustered", :type => :string
                opt :index, "index to cluster on when using single table (otherwise ignored)", :type => :string
            end
            Trollop::die :db, "database name must be given" if @opts[:db] == nil

            @conn = PG.connect( dbname: opts[:db], host: opts[:host], user: opts[:user], password: opts[:password], connect_timeout: 7200 )
            puts "Connected to Database #{opts[:db]} on #{opts[:host]} as user #{opts[:user]}"

            @lower_limit = @opts[:minsize] * 1024 * 1024
        end

        def self.run!
            o = self.new

            o.get_all_tables
            puts "Found #{o.tables.size} Tables in Database #{o.opts[:db]}..."

            o.filter_tables_with_lower_limit_and_update_total_size
            puts "#{o.tables.size} of them are bigger than #{o.lower_limit/(1024*1024)} MB including indexes..."
            puts "The Database has a Total Size of #{o.total_size/(1024*1024)} MB..."

            if o.tables.size == 0
                "nothing todo: exiting..."
                return false
            end

            o.cluster_tables
            puts "Finished clustering Database #{o.opts[:db]}"

            o.get_all_tables
            o.filter_tables_with_lower_limit_and_update_total_size
            puts "The Database now has a Total Size of #{o.total_size/(1024*1024)} MB..."

        end


        def get_all_tables
            @tables = []
            if @opts[:table]
                @tables << @opts[:table]
            else
                @conn.exec( "select relname from pg_stat_user_tables WHERE schemaname='public'" ) do |result|
                    result.each do |row|
                        @tables << row.values_at('relname').first
                    end
                end
            end
        end

        def filter_tables_with_lower_limit_and_update_total_size
            @big_tables = []
            @total_size = 0
            @tables.each do |table|
               @conn.exec( "select pg_total_relation_size('#{table}');" ) do |result|
                    size = result.first['pg_total_relation_size'].to_i
                    if size > @lower_limit
                        @big_tables << table
                    end
                    @total_size += size
                end
            end
            @tables = @big_tables
        end

        def find_indexes(table)
            indexes = {}
            @conn.exec( "select indexname, indexdef from pg_indexes where tablename = '#{table}'" ) do |result|
                result.each do |row|
                    indexes[row.values_at('indexname').first] = row.values_at('indexdef').first
                end
            end
            indexes
        end

        def find_primary_index(table)
            primary_index = {}

            if @opts[:index]
                primary_index = @opts[:index]
            else
                sql = <<-SQL
                    SELECT
                      i.relname, attname
                    FROM pg_index, pg_class i, pg_class t, pg_attribute
                    WHERE
                      t.oid = '#{table}'::regclass AND
                      indrelid = t.oid AND
                      pg_attribute.attrelid = t.oid AND
                      pg_attribute.attnum = any(pg_index.indkey)
                      AND indisprimary
                      AND i.oid = pg_index.indexrelid;
                SQL

                @conn.exec(sql) do |result|
                    result.each do |row|
                        primary_index[result.first['relname']] = result.first['attname']
                    end
                end
            end
            primary_index
        end

        def find_most_used_btree_index(indexes)
            btree_idx = nil
            highest_num_of_scans = -1
            indexes.each do |idx_name, command|
                if command.match("USING btree")
                    #if it is a btree go and check no of scans
                    @conn.exec( "select idx_scan from pg_stat_all_indexes where indexrelname = '#{idx_name}'" ) do |result|
                        scans = result.first['idx_scan'].to_i
                        if scans > highest_num_of_scans
                            highest_num_of_scans = scans
                            btree_idx = idx_name
                        end
                    end
                end
            end
            btree_idx
        end

        def find_triggers(table)
            triggers = {}

            conn.exec( "select * from information_schema.triggers where event_object_table = '#{table}'" ) do |result|
                result.each do |row|
                    if triggers[row.values_at('trigger_name').first]
                        triggers[row.values_at('trigger_name').first][1] = triggers[row.values_at('trigger_name').first][1] +
                                                                                    " OR " +
                                                                                    row.values_at('event_manipulation').first
                    else
                        triggers[row.values_at('trigger_name').first] = [
                            row.values_at('action_timing').first,
                            row.values_at('event_manipulation').first,
                            row.values_at('action_orientation').first,
                            row.values_at('action_statement').first
                        ]
                    end
                end
            end
            triggers.map{|k,v| [ "CREATE TRIGGER", k, v[0..1], "ON", table, "FOR EACH", v[2..3], ";"].join(" ")}
        end

        def generate_sql(table, primary_index, indexes, cluster_index, triggers)
            prefix = opts[:prefix]
            sql = []
            sql << "BEGIN;"
            sql << "LOCK TABLE #{table} IN EXCLUSIVE MODE;"
            sql << "CREATE TABLE #{prefix}_#{table} (LIKE #{table} INCLUDING DEFAULTS INCLUDING CONSTRAINTS INCLUDING COMMENTS);"
            sql << "INSERT INTO #{prefix}_#{table} SELECT * FROM #{table};"
            indexes.each do |idx_name, command|
                sql << command.gsub(" #{idx_name} ", " #{prefix}_#{idx_name} ").gsub("ON #{table} ", "ON #{prefix}_#{table} ") + ";"
            end
            if primary_index.size > 0
                sql << "ALTER TABLE #{prefix}_#{table} ADD PRIMARY KEY (#{primary_index.values.first});"
            end
            sql << "CLUSTER #{prefix}_#{table} USING #{prefix}_#{cluster_index};"
            sql << "DROP TABLE #{table} CASCADE;"
            sql << "ALTER TABLE #{prefix}_#{table} RENAME TO #{table};"

            if primary_index.size > 0
                sql << "ALTER INDEX #{prefix}_#{primary_index.keys.first} RENAME TO #{primary_index.keys.first};"
            end

            indexes.each do |idx_name, command|
                sql << "ALTER INDEX #{prefix}_#{idx_name} RENAME TO #{idx_name};"
            end
            triggers.each do |trigger|
                sql << trigger
            end
            sql << "COMMIT;"
            sql << "ANALYZE #{table};"
            sql.join("\n")
        end

        def cluster_tables
            @tables.each do |table|
                puts "starting to cluster #{table}..."

                puts "fetching indexes..."
                indexes = find_indexes(table)
                primary_index = {}
                cluster_index = nil

                if indexes.size == 0
                    puts "no index found: skipping..."
                    next
                else
                    puts "found #{indexes.size} indexes..."
                end

                primary_index = find_primary_index(table)

                if primary_index.size > 0
                    puts "found primary index: using for clustering..."
                    cluster_index = primary_index.keys.first
                    indexes.delete(primary_index.keys.first)
                else
                    puts "no primary index found: searching for most used btree index"
                end

                unless cluster_index
                    cluster_index = find_most_used_btree_index(indexes)
                end

                unless cluster_index
                    puts "no btree index found: skipping..."
                    next
                end

                triggers = find_triggers(table)

                puts "start to cluster #{table} using #{cluster_index}"

                sql = generate_sql(table, primary_index, indexes, cluster_index, triggers)

                puts 'Executing query:'
                puts sql

                @conn.exec(sql)
                #puts sql

                puts "Successfully clustered #{table}!"
            end
        end
    end
end
