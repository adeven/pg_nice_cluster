# pg_nice_cluster
this is a little tool to help you use the CLUSTER command of postgres while maintaining the ability to read from the table.

## installation
in your Gemfile add

    gem 'pg_nice_cluster', :git => 'git://github.com/adeven/pg_nice_cluster.git'
    
then

    bundle install

## usage
    pg_nice_cluster --help

    Options:
         --db,      -d <s>:   database name
         --user,    -u <s>:   user name (default: postgres)
         --pass,    -p <s>:   password
         --host,    -h <s>:   host name (default: localhost)
         --prefix,  -r <s>:   prefix for the temporary tables and indexes (default 'cluster_') (default: cluster)
         --minsize, -m <i>:   cut off size for small tables in mb (default: 100)
         --table,   -t <s>:   table name if only one table should be clustered
         --index,   -i <s>:   index to cluster on when using single table (otherwise ignored)
         --help,    -e:   Show this message

## requirements
* tables will be EXCLUSIVE locked for the operation
* enough disk space for the biggest table times two
* enough ram for the indexes of the table with the largest combined indexes
* depending on your table size, quite some time