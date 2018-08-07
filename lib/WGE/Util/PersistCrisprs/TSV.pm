package WGE::Util::PersistCrisprs::TSV;
## no critic(RequireUseStrict,RequireUseWarnings)
{
    $WGE::Util::PersistCrisprs::TSV::VERSION = '0.117';
}
## use critic


use Moose;

with qw( WGE::Util::PersistCrisprs );

has '+configfile' => (
    default => $ENV{WGE_REST_CLIENT_CONFIG},
);

has qw( tsv_file ) => (
    is       => 'ro',
    isa      => 'Path::Class::File',
    required => 1,
    coerce   => 1,
);

=head2 execute

Run all the usual steps in order and commit it. This is 
just the most common usage of this module

=cut
sub execute {
    my $self = shift;

    $self->create_temp_table;
    $self->run_update_query;

    #if we get here without dying everything was successful
    if ( $self->dry_run ) {
        $self->log->debug( "Dry run -- rolling back" );
        $self->rollback;
    }
    else {
        $self->log->debug( "Committing to DB" );
        $self->commit;
    }

    return 1;
}

sub create_temp_table {
    my ( $self ) = @_;

    $self->log->info( "Creating temporary table" );

    $self->dbh->do( "CREATE TEMP TABLE ots (c_id INTEGER, species_id INTEGER, ids INTEGER[], summary TEXT) ON COMMIT DROP" );
    $self->dbh->do( "COPY ots (c_id, species_id, ids, summary) FROM STDIN" );

    #stream the file into our COPY command
    my $fh = $self->tsv_file->openr;
    while ( my $line = <$fh> ) {
        $self->dbh->pg_putcopydata( $line );
    }

    $self->dbh->pg_putcopyend();

    return 1;
}

sub run_update_query {
    my ( $self ) = @_;

    #now do an update on our temporary table
    my $query = <<EOT;
UPDATE crisprs c
SET off_target_summary=ots.summary, off_target_ids=ots.ids
FROM ots
WHERE c.id=ots.c_id AND c.species_id=ots.species_id
EOT

    my $res = $self->dbh->do( $query );
    handle_error( "No rows were updated!", $self->dbh ) 
        if ! defined $res || $res eq "0E0";

    $self->log->info( "Updated $res rows" );
}

1;

__END__

=head1 NAME

WGE::Util::PersistCrisprs::TSV - persist crispr data from TSV file

=head1 DESCRIPTION

Load crispr off target data from a TSV file generated by find_off_targets.

=head AUTHOR

Alex Hodgkins

=cut