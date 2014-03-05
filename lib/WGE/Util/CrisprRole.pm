package WGE::Util::CrisprRole;

use Moose::Role;

requires qw( chr_start pam_right species_id result_source );

#these methods are required by multiple resultsets,
#to use them just add 
#with 'WGE::Util::CrisprRole'

#CHECK THESE NUMBERS!! we want either the start or end of sgrna
sub pam_start {
    my $self = shift;
    return $self->chr_start + ($self->pam_right ? 19 : 2)
}

sub pam_left {
    return ! shift->pam_right;
}

sub chr_end {
    return shift->chr_start + 22;
}

sub get_species {
    my $self = shift;

    return $self->result_source->schema->resultset('Species')->find( 
        { numerical_id => $self->species_id } 
    )->id;
}

1;