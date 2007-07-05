package Netdot::Model;

use base qw ( Class::DBI  Netdot );
use Netdot::Model::Nullify;

=head1 NAME

Netdot::Model - Netdot implementation of the Model layer (of the MVC architecture)

    This base class includes logic common to all classes that need access to the stored data.
    It is not intended to be used directly.

=head1 SYNOPSIS
    
    
=cut

my %defaults; 
my $logger = Netdot->log->get_logger("Netdot::Model");


BEGIN {
    my $db_type  = __PACKAGE__->config->get('DB_TYPE');
    my $database = __PACKAGE__->config->get('DB_DATABASE');
    my $host     = __PACKAGE__->config->get('DB_HOST');
    my $port     = __PACKAGE__->config->get('DB_PORT');

    $defaults{dsn}  = "dbi:$db_type:database=$database";
    $defaults{dsn} .= ";host=$host" if defined ($host); 
    $defaults{dsn} .= ";port=$port" if defined ($port); 
    $defaults{user}        = __PACKAGE__->config->get('DB_NETDOT_USER');
    $defaults{password}    = __PACKAGE__->config->get('DB_NETDOT_PASS');
    $defaults{dbi_options} = { __PACKAGE__->_default_attributes };
    $defaults{dbi_options}->{AutoCommit} = 1;

    # Tell Class::DBI to connect to the DB
    __PACKAGE__->connection($defaults{dsn}, 
			    $defaults{user}, 
			    $defaults{password}, 
			    $defaults{dbi_options});


    ###########################################################
    # Copy stored object in corresponding history table 
    #  - Before updating
    #  - After creating
    # This must be defined here (before loading the classes).  
    ###########################################################
    __PACKAGE__->add_trigger( before_update => \&_historize );
    __PACKAGE__->add_trigger( after_create  => \&_historize );
    
    sub _historize {
	my $self     = shift;
	my $table    = $self->table;
	my $h_table  = $self->meta_data->get_history_table_name();
	return unless $h_table;  # this object does not have a history table
	my $dbh      = $self->db_Main();
	my $col_list = join ",", $self->columns;
	my $id       = $self->id;
	my @vals = $dbh->selectrow_array("SELECT $col_list FROM $table WHERE id = $id");
	my %current_data;
	my $i = 0;
	map { $current_data{$_} = $vals[$i++] } $self->columns;
	delete $current_data{id}; # Our id is different
	my $oid = $table."_id"; # fk pointing to the real object's id
	$current_data{$oid}     = $self->id;
	$current_data{modified} = $self->timestamp;
	$current_data{modifier} = $ENV{REMOTE_USER} || "unknown";
	$h_table->insert(\%current_data);
	1;
    }

    ###########################################################
    # This sub avoids errors like:
    # "Deep recursion on subroutine "Class::DBI::_flesh""
    # when executing under mod_perl
    # Someone suggested using it here:
    # http://lists.digitalcraftsmen.net/pipermail/classdbi/2006-January/000750.html
    # I haven't had time to understand what is really happenning
    ###########################################################
    sub _flesh {
	my $this = shift;
	if(ref($this) && $this->_undefined_primary) {
	    $this->call_trigger("select");
	    return $this;
	}
	return $this->SUPER::_flesh(@_);
    }

    # Get CDBI subclasses and load them here
    my $subclasses = __PACKAGE__->meta->cdbi_classes(base      => __PACKAGE__,
						     namespace => __PACKAGE__,
						     );
    my $code = "";
    foreach my $class ( values %{ $subclasses } ){
	$code .= $class;
    }
    eval $code;
    croak $@ if ($@);

    # This section will attempt to load a Perl module with the same name
    # as each class that was just autogenerated, so we can extend the 
    # functionality of our classes.  The modules must be located
    # in a directory that can be found by the 'use' call.
    foreach my $class ( keys %{ $subclasses } ){
	eval "use $class";
	if($@) { if($@ !~ /^Can.t locate /) { croak $@ } }
    }
    
    # This section will allow us to continue to say 
    # Table->method instead of Netdot::Model::Table->method.
    # This could go away if we decide to change all our
    # existing code to use the full class names
    foreach my $mtable ( __PACKAGE__->meta->get_tables(with_history=>1) ){
	my $code = sprintf ("package %s; use base '%s::%s'; ", 
			    $mtable->name, __PACKAGE__, $mtable->name);
	eval $code;
	croak $@ if ($@);
    }
    
    #########################################################
    # Override db_Main to avoid problems between Class::DBI
    # and Apache::DBI. See:
    # http://wiki.class-dbi.com/wiki/Using_with_mod_perl

    __PACKAGE__->_remember_handle('Main'); # so dbi_commit works
    
    # Note, this subroutine *has* to be inside the BEGIN block, 
    # otherwise the call to SUPER:: won't work (it might have to do
    # with the fact that it is resolved at compile time, not
    # at run time)
    
    sub db_Main {
	my $self = shift;
	my $dbh;
	if ( $ENV{'MOD_PERL'} and !$Apache::ServerStarting ) {
	    $dbh = Apache->request()->pnotes('dbh');
	}else{
	    $dbh = $self->SUPER::db_Main();
	}
	if ( !$dbh ) {
	    $dbh = DBI->connect_cached($defaults{dsn}, $defaults{user}, 
				       $defaults{password}, $defaults{dbi_options});
	    
	    if ( $ENV{'MOD_PERL'} and !$Apache::ServerStarting ) {
		Apache->request()->pnotes( 'dbh', $dbh );
	    }
	}
	return $dbh;
    }

}

=head1 CLASS METHODS
=cut
############################################################################
=head2 insert - Insert (create) a new object

  Arguments:
    Hash with field/value pairs
  Returns:
    Newly insrted object
  Examples:
    my $newobj = SomeClass->insert({field1=>val1, field2=>val2});

=cut
sub insert {
    my ($class, $argv) = @_;
    $class->isa_class_method('insert');

    $class->throw_fatal("insert needs field/value parameters") 
	unless ( keys %{$argv} );
    
    $class->_adjust_vals($argv);
    my $obj;
    eval {
	$obj = $class->SUPER::insert($argv);
    };
    if ( my $e = $@ ){
	# Class::DBI shows a full stack trace
	# Try to make it less frightening for the user
	if ( $e =~ /Duplicate entry/i ){
	    $e = "$class Insert error:  One or more fields were detected as duplicate.";
	}elsif ( $e =~ /cannot be null|not-null constraint/i ){
	    $e = "$class Insert error:  One or more fields cannot be null.";
	}elsif ( $e =~ /invalid input syntax/i ){
	    $e = "$class Insert error: One or more fields have invalid input syntax.";
	}elsif ( $e =~ /out of range/i ){
	    $e = "$class Insert error: One or more values are out of valid range.";
	}
	$class->throw_user($e);
    }

    $logger->debug( sub { sprintf("Model::insert: Inserted new record %i in table: %s", 
				  $obj->id, $obj->table) } );
    
    return $obj;
}

############################################################################
=head2 search_like - Search with wildcards

    We override the base method to add wildcard characters at the beginning
    and end of the search string by default.  
    User can also specify exact search by enclosing search terms within 
    quotation marks (''), or use their own shell-style wildcards (*,?),
    which will be translated into SQL-style (%,_)

  Arguments:
    hash with key/value pairs
  Returns:
    See Class::DBI search_like()
  Examples:
    my @objs = SomeClass->search_like(field1=>val1, field2=>val2);

=cut
sub search_like {
    my ($class, %argv) = @_;
    $class->isa_class_method('search_like');
    
    foreach my $key ( keys %argv ){
	$argv{$key} = $class->_convert_search_keyword($argv{$key});
    }
    return $class->SUPER::search_like(%argv);
}

############################################################################
=head2 timestamp - Get timestamp in DB 'datetime' format

  Arguments:
    None
  Returns:
    String
  Examples:
    $lastseen = $obj->timestamp();

=cut
sub timestamp {
    my $class  = shift;
    my ($seconds, $minutes, $hours, $day_of_month, 
	$month, $year,$wday, $yday, $isdst) = localtime;
    my $datetime = sprintf("%04d\/%02d\/%02d %02d:%02d:%02d",
			   $year+1900, $month+1, $day_of_month, $hours, $minutes, $seconds);
    return $datetime;
}

############################################################################
=head2 date - Get date in DB 'date' format

  Arguments:
    None
  Returns:
    String
  Examples:
    $lastupdated = $obj->date();

=cut
sub date {
    my $class  = shift;
    my ($seconds, $minutes, $hours, $day_of_month, $month, $year,
	$wday, $yday, $isdst) = localtime;
    my $date = sprintf("%04d\/%02d\/%02d",
			   $year+1900, $month+1, $day_of_month);
    return $date;
}


############################################################################
=head2 meta_data - Return Meta::Table object associated with this object or class

  Arguments:
    None
  Returns:
    Meta::Table object
  Examples:
    my @device_columns = $dev->meta_data->get_column_names();

=cut
sub meta_data {
    my $self = shift;
    my $table;
    $table = $self->short_class();
    return $self->meta->get_table($table);
}

############################################################################
=head2 short_class - Return the short version of a class name.  It can also be called as a Class method.
    
  Arguments:
    None
  Returns:
    Short class name
  Examples:
    # This returns 'Device' instead of Netdot::Model::Device
    $class = $dev->short_class();
=cut
sub short_class {
    my $self = shift;

    my $class = ref($self) || $self;
    if ( $class =~ /::(\w+)$/ ){
	$class = $1;
    }
    return $class;
}

############################################################################
=head2 raw_sql - Issue SQL queries directly

    Returns results from an SQL query

 Arguments: 
    SQL query (string)
 Returns:  
    Reference to a hash of arrays. 
    When using SELECT statements, the keys are:
     - headers:  array containing column names
     - rows:     array containing column values

    When using NON-SELECT statements, the keys are:
     - rows:     array containing one string, which states the number
                 of rows affected
  Example:
    $result = Netdot::Model->raw_sql($sql)

    my @headers = $result->{headers};
    my @rows    = $result->{rows};

    # In a Mason component:
    <& /generic/data_table.mhtml, field_headers=>@headers, data=>@rows &>

=cut
sub raw_sql {
    my ($self, $sql) = @_;
    my $dbh = $self->db_Main;
    my $st;
    my %result;
    if ( $sql =~ /select/i ){
    	eval {
    	    $st = $dbh->prepare_cached( $sql );
    	    $st->execute();
    	};
    	if ( $@ ){
            # parse out SQL error message from the entire error
            my ($errormsg) = $@ =~ m{execute[ ]failed:[ ](.*)[ ]at[ ]/};
    	    $self->error("SQL Error: $errormsg");
    	    return;
    	}

        $result{headers} = $st->{"NAME_lc"};
        $result{rows}    = $st->fetchall_arrayref;

    }elsif ( $sql =~ /delete|update|insert/i ){
    	my $rows;
    	eval {
    	    $rows = $dbh->do( $sql );
    	};
    	if ( $@ ){
    	    $self->throw_fatal("raw_sql Error: $@");
    	    return;
    	}
    	$rows = 0 if ( $rows eq "0E0" );  # See DBI's documentation for 'do'

        my @info = ('Rows Affected: '.$rows);
        my @rows;
        push( @rows, \@info );
        $result{rows} = \@rows;
    }else{
    	$self->throw_user("raw_sql Error: Only select, delete, update and insert statements accepted");
    	return;
    }
    return \%result;
}

############################################################################
=head2 do_transaction - Perform an operation "atomically".
    
    A reference to a subroutine is passed, together with its arguments.
    If anything fails within the operation, any DB changes made since the 
    start are rolled back.  
    
  Arguments:
    code - code reference
    args - array of arguments to pass to subroutine
    
  Returns:
    results from code ref
    
  Example: (*)
    
    $r = Netdot::Model->do_transaction( sub{ return $dev->snmp_update(@_) }, %argv);

    (*) Notice the correct way to get a reference to an object\'s method
        (See section 4.3.6 - Closures, from "Programming Perl")

=cut

# This method has been adapted from an example offered here:
# http://wiki.class-dbi.com/wiki/Using_transactions

sub do_transaction {
    my ($self, $code, @args) = @_;
    $self->isa_class_method('do_transaction');

    my @result;
    my $dbh = $self->db_Main();

    # Localize AutoCommit database handle attribute
    # and turn off for this block.
    local $dbh->{AutoCommit};

    eval {
        @result = $code->(@args);
	$self->dbi_commit;
    };
    if ( my $e = $@ ) {
        $self->clear_object_index;
	eval { $self->dbi_rollback; };
	my $rollback_error = $@;
	if ( $rollback_error ){
	    $self->throw_fatal("Transaction aborted: $e; "
				. "(Rollback failed): $rollback_error\n");
        }else{
	    if ( ref($error) =~ /Netdot::Util::Exception/  &&
		 $e->isa_netdot_exception('User') ){
		# Rethrow
		$self->throw_user("Transaction aborted " 
				   . "(Rollback successful): $e\n");
	    }else{
		$self->throw_fatal("Transaction aborted " 
				   . "(Rollback successful): $e\n");
	    }
	}
        return;
    }
    wantarray ? @result : $result[0];
} 

############################################################################
=head2 db_auto_commit - Set the AutoCommit flag in DBI for the current db handle

 Arguments: Flag value to be set (1 or 0)
 Returns:   Current value of the flag (1 or 0)

=cut
sub db_auto_commit {
    my $self = shift;
    $self->isa_class_method('db_auto_commit');

    my $dbh = $self->db_Main;
    if ( @_ ) { $dbh->{AutoCommit} = shift };
    return $dbh->{AutoCommit};
}

=head1 INSTANCE METHODS
=cut

############################################################################
=head2 update - Update object in DB

  We combine Class::DBI\'s set() and update() into one method.  
  If called with no arguments, assumes values have been set() and calls update() only.

  Arguments:
    hashref  containing key/value pairs (optional)
  Returns: 
    See Class::DBI update()
  Examples:
    $obj->update({field1=>value1, field2=>value2});

=cut
sub update {
    my ($self, $argv) = @_;
    $self->isa_object_method('update');
    my $class = ref($self);
    if ( $argv ){
	$class->_adjust_vals($argv);
	$self->set( %$argv );
    }

    my @changed_keys;
    my $id = $self->id;
    my $res;
    if ( @changed_keys = $self->is_changed() ){
	eval {
	    $res = $self->SUPER::update();
	};
	if ( my $e = $@ ){
	    # Class::DBI shows a full stack trace
	    # Try to make it less frightening for the user
	    if ( $e =~ /Duplicate/i ){
		$e = "$class Update error:  One or more fields are invalid duplicates";
	    }elsif ( $e =~ /invalid input syntax/i ){
		$e = "$class Update error: One or more fields have invalid input syntax";
	    }elsif ( $e =~ /out of range/i ){
		$e = "$class Update error: One or more values are out of valid range.";
	    }

	    $self->throw_user($e);
	}
	# For some reason, we (with some classes) get an empty object after updating (weird)
	# so we re-read the object from the DB to make sure we have the id value below:
	$self = $class->retrieve($id);
	$logger->debug( sub { sprintf("Model::update: Updated table: %s, id: %s, fields: %s", 
				      $self->table, $self->id, (join ", ", @changed_keys) ) } );
    }
    return $res;
}

############################################################################
=head2 delete - Delete an existing object

  Arguments:
    None
  Returns:
    True if successful
  Examples:
    $obj->delete();

=cut
sub delete {
    my $self = shift;
    $self->isa_object_method('delete');
    $self->throw_fatal("delete does not take any parameters") if shift;

    my ($id, $table) = ($self->id, $self->table);
    eval {
	$self->SUPER::delete();
    };
    if ( my $e = $@ ){
	if ( $e =~ /objects still refer to/i ){
	    $e = "Other objects refer to this object.  Delete failed.";
	}
	$self->throw_user($e);
    }
    $logger->debug( sub { sprintf("Model::delete: Deleted record %i, from table: %s", 
				  $id, $table) } );
    
    return 1;
}

############################################################################
=head2 get_state - Get current state of an object

    Get a hash with column/value pairs from this object.
    Useful if object needs to be restored to a previous
    state after changes have been committed.

  Arguments:
    None
  Returns:
    Hash with column/value pairs
  Examples:

    my %state = $obj->get_state;

=cut
sub get_state {
    my ($self, $obj) = @_;
    $self->isa_object_method('get_state');

    my %bak;
    my $class  = $self->short_class;
    my @cols   = $class->columns();
    my @values = $self->get( @cols );
    my $n = 0;
    foreach my $col ( @cols ){
	$bak{$col} = $values[$n++];
    }
    return %bak;
}

##################################################################
=head2 get_label - Get label string

    Returns an object\'s label string, composed of the values 
    of a list of label fields, defined in metadata,
    which might reside in more than one table.
    Specific classes might override this method.

Arguments:
    (Optional) field delimiter (default: ', ')
Returns:
    String
Examples:
    print $obj->get_label();

=cut
sub get_label {
    my ($self, $delim) = @_;
    $self->isa_object_method('get_label');

    $delim ||= ', ';  # default delimiter

    my @lbls = $self->meta_data->get_labels();

    my @ret;
    foreach my $c ( @lbls ){
	my $mcol;
	if ( defined($self->$c) && ($mcol = $self->meta_data->get_column($c)) ){
	    if ( ! $mcol->links_to() ){
		push @ret, $self->$c;
	    }else{
		# The field is a foreign key
		push @ret, $self->$c->get_label($delim);
	    }
	}
    }
    # Only want non empty fields
    return join "$delim", grep {$_ ne ""} @ret ;
}

############################################################################
=head2 ge_history - Get a list of history objects for a given object

  Arguments:
    None
  Returns:
    Array of history records associated with this object, ordered
    by modified time, newest first.
  Example:
    my @h = $obj->get_history();

=cut
sub get_history {
    my ($self, $o) = @_;
    $self->isa_object_method('get_history');

    my $table  = $self->table;
    my $htable = $self->meta_data->get_history_table_name();

    # History objects have two indexes, one is the necessary
    # unique index, the other one refers to which real object
    # this is the history of.
    # The latter has the table's name plus the "_id" suffix

    my $id_f = lc("$table" . "_id");
    my @ho;
    return $htable->search($id_f=>$self->id, {order_by => 'modified DESC'});
}

############################################################################
=head2 search_all_tables - Search for a string in all fields from all tables, excluding foreign key fields.

Arguments:  query string
Returns:    reference to hash of hashes

=cut
sub search_all_tables {
    my ($self, $q) = @_;
    my %results;

    # Ignore these fields when searching
    my %ign_fields = ('id' => '');

    $q = $self->_convert_search_keyword($q);

    foreach my $tbl ( $self->meta->get_table_names() ) {
	# Will also ignore foreign key fields
	my @cols;
	map { push @cols, $_ 
		  unless( exists $ign_fields{$_} || 
			  defined $tbl->meta_data->get_column($_)->links_to ) 
	      } $tbl->columns();
	my @where;
	map { push @where, "$_ LIKE \"$q\"" } @cols;
	my $where = join " or ", @where;
	next unless $where;
	my $dbh = $self->db_Main;
	my $st;
	eval {
	    $st = $dbh->prepare_cached("SELECT id FROM $tbl WHERE $where;");
	    $st->execute();
	};
	if ( $@ ){
	    $self->throw_fatal("search_all_tables: $@");
	}
	while ( my ($id) = $st->fetchrow_array() ){
	    $results{$tbl}{$id} = $tbl->retrieve($id);
	}
    }
    return \%results;
}

##################################################################
#
# Private Methods
#
##################################################################

############################################################################
# _adjust_vals - Adjust field values before inserting/updating
# 
#    Make sure to set integer and bool fields to 0 instead of the empty string.
#    Ignore the empty string when inserting/updating date fields.
#
# Arguments:
#   hash ref with key/value pairs
# Returns:
#   True
# Examples:
#
sub _adjust_vals{
    my ($self, $args) = @_;
    $self->isa_class_method('_adjust_vals');
    foreach my $field ( keys %$args ){
	my $mcol = $self->meta_data->get_column($field);
	if ( $args->{$field} eq "" || $args->{$field} =~ /^null$/i){
	    if ( $mcol->sql_type =~ /integer|bool/i ){
		$logger->debug( sub { sprintf("Model::_adjust_vals: Setting empty field '%s' type '%s' to 0.", 
					      $field, $mcol->sql_type) } );
		$args->{$field} = 0;
	    }elsif ( $mcol->sql_type =~ /date/i ){
		$logger->debug( sub { sprintf("Model::_adjust_vals: Removing empty field %s type %s.", 
					      $field, $mcol->sql_type) } );
		delete $args->{$field};
	    }
	}
    }
    return 1;
}

##################################################################
#_convert_search_keyword - Transform a search keyword into exact or wildcarded
#
#    Search keywords between quotation marks ('') are interpreted
#    as exact matches.  Otherwise, SQL wildcards are prepended and appended.
#
#  Arguments:
#   keyword
#  Returns:
#    Scalar containing transformed keyword string
#  Examples:
#

sub _convert_search_keyword {
    my ($self, $keyword) = @_;
    my $new;
    $self->isa_class_method("_convert_search_keyword");

    # Remove leading and trailing spaces
    $keyword =~ s/^\s*(.*)\s*$/$1/;

    if ( $keyword =~ /^'(.*)'$/ ){
	# User wants exact match
	$new = $1;
    }elsif( $keyword =~ /[\*\?]/ ){
	# Translate wildcards into SQL form
	$keyword =~ s/\*/%/g;
	$keyword =~ s/\?/_/g;	
	$new = $keyword;
    }else{
	# Add wildcards at beginning and end
	$new =  "%" . $keyword . "%";
    }
    $logger->debug("Model::_convert_search_keyword: Converted $keyword into $new");
    return $new;
}


=head1 AUTHOR

Carlos Vicente, C<< <cvicente at ns.uoregon.edu> >>

=head1 COPYRIGHT & LICENSE

Copyright 2006 University of Oregon, all rights reserved.

This program is free software; you can redistribute it and/or modify
it under the terms of the GNU General Public License as published by
the Free Software Foundation; either version 2 of the License, or
(at your option) any later version.

This program is distributed in the hope that it will be useful, but
WITHOUT ANY WARRANTY; without even the implied warranty of MERCHANTIBILITY
or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU General Public
License for more details.

You should have received a copy of the GNU General Public License
along with this program; if not, write to the Free Software Foundation,
Inc., 59 Temple Place - Suite 330, Boston, MA 02111-1307, USA.

=cut

# Make sure to return 1
1;


