package WGE::Util::ScoreCrisprs;
use strict;
use warnings;

use WGE::Util::GenomeBrowser qw(get_region_from_params);
use WGE::Util::GenomeBrowser qw(crisprs_for_region_as_arrayref);

use Sub::Exporter -setup => {
    exports => [ qw(
        retrieve_crisprs_as_arrayref
        score_and_sort_crisprs
    ) ]
};

#Using provided parameters, find crisprs in the browser view
sub retrieve_crisprs_as_arrayref{
    my ($c, $location) = @_;
    my $schema = $c->model('DB');

    #Breakdown url
    my @end_points = split(/_/, $location);
    my $params = {
        browse_start => $end_points[0],
        browse_end => $end_points[1],
        genome => $end_points[2],
        species => $end_points[3],
        species_id => $end_points[3],
        chromosome => $end_points[4],
    };

    #Obtain chromosome id
    my $region = get_region_from_params($schema, $params);
    $params->{chromosome_number} = $region->{chromosome};

    #Reconstruct hash to suit search requirements
    $params->{start_coord} = $params->{browse_start};
    $params->{end_coord} = $params->{browse_end};
    return crisprs_for_region_as_arrayref($schema,$params),$params;

}

#Each OT calculated crispr is given a score. Golf style - lower the score, the better
sub score_and_sort_crisprs {
    my ($crispr_arrayref) = @_;
    my @scored_crisprs;

    foreach my $item (@$crispr_arrayref){
        #Remove unwanted symbols
        my @trim = trim_off_targets($item);

        my $score = score_off_targets(@trim);
        $item->{score} = $score;

        #Ignore crisprs missing OTs
        if ($item->{score} > 0){
            push(@scored_crisprs, $item);
        }
    }

    my @sorted_crisprs = sort_by_score(@scored_crisprs);
    return @sorted_crisprs;
}

#Remove unnecessary symbols from the off-target summary
sub trim_off_targets {
    my ($crispr) = @_;
    my $off_targets = $crispr->{off_target_summary};
    my @targets = split(/,/,$off_targets);

    foreach my $item (@targets){
        $item =~ tr/;{}' //d;
    }
    return @targets;
}

#Score each crispr's off-targets 0-4096, 1-512, 2-64, 3-8, 4-1
#Scores increase exponentially to show the increase likelihood of a mismatch
sub score_off_targets {
    my (@trimmed_summary) = @_;

    my %weights = map { $_ => 1 << ( 3 * ( 4 - $_ ) ) } 0 .. 4;
    my $score = 0;

    foreach my $current_off_target (@trimmed_summary){
        my ( $distance, $quantity ) = split(/:/, $current_off_target);
        #Adjust scoring weight depending on off-target differences
        if ( exists $weights{$distance} ) {
            $score += $weights{$distance} * $quantity;
        }
        else {
            print "Invalid crispr off-target - out of bounds";
        }
    }

    #Ignore self
    $score = $score - $weights{0};

    return $score;
}

#Sorts the array by score. Lowest score first
sub sort_by_score{
    my (@scored) = @_;
    my @sorted_array_of_hashes = sort { $a->{score} <=> $b->{score} } @scored;
    return @sorted_array_of_hashes;
}

1;