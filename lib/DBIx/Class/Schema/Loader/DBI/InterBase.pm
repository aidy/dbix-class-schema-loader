package DBIx::Class::Schema::Loader::DBI::InterBase;

use strict;
use warnings;
use namespace::autoclean;
use Class::C3;
use base qw/DBIx::Class::Schema::Loader::DBI/;
use Carp::Clan qw/^DBIx::Class/;
use List::Util 'first';

__PACKAGE__->mk_group_ro_accessors('simple', qw/
    unquoted_ddl
/);

our $VERSION = '0.05003';

=head1 NAME

DBIx::Class::Schema::Loader::DBI::InterBase - DBIx::Class::Schema::Loader::DBI
Firebird Implementation.

=head1 DESCRIPTION

See L<DBIx::Class::Schema::Loader::Base> for available options.

By default column names from unquoted DDL will be generated in uppercase, as
that is the only way they will work with quoting on.

See the L</unquoted_ddl> option in this driver if you would like to have
lowercase column names.

=head1 DRIVER OPTIONS

=head2 unquoted_ddl

Set this loader option if your DDL uses unquoted identifiers and you will not
use quoting (the L<quote_char|DBIx::Class::Storage::DBI/quote_char> option in
L<connect_info|DBIx::Class::Storage::DBI/connect_info>.)

This will generate lowercase column names (as opposed to the actual uppercase
names) in your Result classes that will only work with quoting off.

Mixed-case table and column names will be ignored when this option is on and
will not work with quoting turned off.

=cut

sub _is_case_sensitive {
    my $self = shift;

    return $self->unquoted_ddl ? 0 : 1;
}

sub _setup {
    my $self = shift;

    $self->next::method;

    $self->schema->storage->sql_maker->name_sep('.');

    if (not $self->unquoted_ddl) {
        $self->schema->storage->sql_maker->quote_char('"');
    }
    else {
        $self->schema->storage->sql_maker->quote_char(undef);
    }
}

sub _lc {
    my ($self, $name) = @_;

    return $self->unquoted_ddl ? lc($name) : $name;
}

sub _uc {
    my ($self, $name) = @_;

    return $self->unquoted_ddl ? uc($name) : $name;
}

sub _table_pk_info {
    my ($self, $table) = @_;

    my $dbh = $self->schema->storage->dbh;
    my $sth = $dbh->prepare(<<'EOF');
SELECT iseg.rdb$field_name
FROM rdb$relation_constraints rc
JOIN rdb$index_segments iseg ON rc.rdb$index_name = iseg.rdb$index_name
WHERE rc.rdb$constraint_type = 'PRIMARY KEY' and rc.rdb$relation_name = ?
ORDER BY iseg.rdb$field_position
EOF
    $sth->execute($table);

    my @keydata;

    while (my ($col) = $sth->fetchrow_array) {
        s/^\s+//, s/\s+\z// for $col;

        push @keydata, $self->_lc($col);
    }

    return \@keydata;
}

sub _table_fk_info {
    my ($self, $table) = @_;

    my ($local_cols, $remote_cols, $remote_table, @rels);
    my $dbh = $self->schema->storage->dbh;
    my $sth = $dbh->prepare(<<'EOF');
SELECT rc.rdb$constraint_name fk, iseg.rdb$field_name local_col, ri.rdb$relation_name remote_tab, riseg.rdb$field_name remote_col
FROM rdb$relation_constraints rc
JOIN rdb$index_segments iseg ON rc.rdb$index_name = iseg.rdb$index_name
JOIN rdb$indices li ON rc.rdb$index_name = li.rdb$index_name
JOIN rdb$indices ri ON li.rdb$foreign_key = ri.rdb$index_name
JOIN rdb$index_segments riseg ON iseg.rdb$field_position = riseg.rdb$field_position and ri.rdb$index_name = riseg.rdb$index_name
WHERE rc.rdb$constraint_type = 'FOREIGN KEY' and rc.rdb$relation_name = ?
ORDER BY iseg.rdb$field_position
EOF
    $sth->execute($table);

    while (my ($fk, $local_col, $remote_tab, $remote_col) = $sth->fetchrow_array) {
        s/^\s+//, s/\s+\z// for $fk, $local_col, $remote_tab, $remote_col;

        push @{$local_cols->{$fk}},  $self->_lc($local_col);
        push @{$remote_cols->{$fk}}, $self->_lc($remote_col);
        $remote_table->{$fk} = $remote_tab;
    }

    foreach my $fk (keys %$remote_table) {
        push @rels, {
            local_columns => $local_cols->{$fk},
            remote_columns => $remote_cols->{$fk},
            remote_table => $remote_table->{$fk},
        };
    }
    return \@rels;
}

sub _table_uniq_info {
    my ($self, $table) = @_;

    my $dbh = $self->schema->storage->dbh;
    my $sth = $dbh->prepare(<<'EOF');
SELECT rc.rdb$constraint_name, iseg.rdb$field_name
FROM rdb$relation_constraints rc
JOIN rdb$index_segments iseg ON rc.rdb$index_name = iseg.rdb$index_name
WHERE rc.rdb$constraint_type = 'UNIQUE' and rc.rdb$relation_name = ?
ORDER BY iseg.rdb$field_position
EOF
    $sth->execute($table);

    my $constraints;
    while (my ($constraint_name, $column) = $sth->fetchrow_array) {
        s/^\s+//, s/\s+\z// for $constraint_name, $column;

        push @{$constraints->{$constraint_name}}, $self->_lc($column);
    }

    my @uniqs = map { [ $_ => $constraints->{$_} ] } keys %$constraints;
    return \@uniqs;
}

sub _extra_column_info {
    my ($self, $table, $column, $info, $dbi_info) = @_;
    my %extra_info;

    my $dbh = $self->schema->storage->dbh;

    local $dbh->{LongReadLen} = 100000;
    local $dbh->{LongTruncOk} = 1;

    my $sth = $dbh->prepare(<<'EOF');
SELECT t.rdb$trigger_source
FROM rdb$triggers t
WHERE t.rdb$relation_name = ?
AND t.rdb$system_flag = 0 -- user defined
AND t.rdb$trigger_type = 1 -- BEFORE INSERT
EOF
    $sth->execute($table);

    while (my ($trigger) = $sth->fetchrow_array) {
        my @trig_cols = map {
            /^"([^"]+)/ ? $1 : uc($1)
        } $trigger =~ /new\.("?\w+"?)/ig;

        my ($quoted, $generator) = $trigger =~
/(?:gen_id\s* \( \s* |next \s* value \s* for \s*)(")?(\w+)/ix;

        if ($generator) {
            $generator = uc $generator unless $quoted;

            if (first { $self->_uc($_) eq $self->_uc($column) } @trig_cols) {
                $extra_info{is_auto_increment} = 1;
                $extra_info{sequence}          = $generator;
                last;
            }
        }
    }

# fix up DT types, no idea which other types are fucked
    if ($info->{data_type} eq '11') {
        $extra_info{data_type} = 'TIMESTAMP';
    }
    elsif ($info->{data_type} eq '9') {
        $extra_info{data_type} = 'DATE';
    }

# get default
    $sth = $dbh->prepare(<<'EOF');
SELECT rf.rdb$default_source
FROM rdb$relation_fields rf
WHERE rf.rdb$relation_name = ?
AND rf.rdb$field_name = ?
EOF
    $sth->execute($table, $self->_uc($column));
    my ($default_src) = $sth->fetchrow_array;

    if ($default_src && (my ($def) = $default_src =~ /^DEFAULT \s+ (\S+)/ix)) {
        if (my ($quoted) = $def =~ /^'(.*?)'\z/) {
            $extra_info{default_value} = $quoted;
        }
        else {
            $extra_info{default_value} = $def =~ /^\d/ ? $def : \$def;
        }
    }

    return \%extra_info;
}

=head1 SEE ALSO

L<DBIx::Class::Schema::Loader>, L<DBIx::Class::Schema::Loader::Base>,
L<DBIx::Class::Schema::Loader::DBI>

=head1 AUTHOR

See L<DBIx::Class::Schema::Loader/AUTHOR> and L<DBIx::Class::Schema::Loader/CONTRIBUTORS>.

=head1 LICENSE

This library is free software; you can redistribute it and/or modify it under
the same terms as Perl itself.

=cut

1;
