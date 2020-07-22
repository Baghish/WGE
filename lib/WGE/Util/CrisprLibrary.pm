package WGE::Util::CrisprLibrary;

use strict;
use warnings FATAL => 'all';

use WGE::Util::ExportCSV qw(format_crisprs_for_csv_header format_crisprs_for_csv_data);
use WGE::Util::ScoreCrisprs qw(score_and_sort_crisprs);
use Data::UUID;
use Path::Class;
use Data::Dumper;
use File::Spec::Functions;
use Moose;
use POSIX qw(ceil sys_wait_h _exit);
use JSON;
use WGE::Util::OffTargetServer;
use List::MoreUtils qw(natatime);
use Text::CSV;
use TryCatch;
use WebAppCommon::Util::EnsEMBL;
use WebAppCommon::Util::JobRunner;
use WebAppCommon::Util::FileAccess;
use IPC::Run 'run';

with 'MooseX::Log::Log4perl';

=head

Find crisprs within/flanking a list of specified search regions

NB: There is some overlap between this and WGE::Util::FindCrisprs which finds
crisprs and pairs for exons

=cut

has model => (
    is  => 'ro',
    isa => 'WGE::Model::DB',
    required => 1,
);

has user_id => (
    is  => 'ro',
    isa => 'Int',
    required => 0,
);

has job_name => (
    is => 'ro',
    isa => 'Str',
    default => '',
);

has input_fh => (
    is  => 'ro',
    isa => 'IO::File',
    required => 1,
);

has species_name => (
    is  => 'ro',
    isa => 'Str',
    required => 1,
);

has location_type => (
    is  => 'ro',
    isa => 'Str',
    required => 1,
);

has num_crisprs => (
    is  => 'ro',
    isa => 'Int',
    default => 1,
);

has within => (
    is => 'ro',
    isa => 'Bool',
    default => 1,
);

has flank_size => (
    is => 'ro',
    isa => 'Int',
    required => 0,
);

has write_progress_to_db => (
    is  => 'rw',
    isa => 'Bool',
    default => 1,
);

has update_after_n_items => (
    is  => 'rw',
    isa => 'Int',
    default => 20,
);

has species_numerical_id => (
    is => 'ro',
    isa => 'Int',
    lazy_build => 1,
);

sub _build_species_numerical_id{
    my ($self) = @_;
    my $species = $self->model->schema->resultset('Species')->search({ id => $self->species_name })->first
        or die "Could not find species ".$self->species_name;
    return $species->numerical_id;
}

has ots_server => (
    is => 'ro',
    isa => 'WGE::Util::OffTargetServer',
    lazy_build => 1,
);

sub _build_ots_server {
    return WGE::Util::OffTargetServer->new;
}

has ensembl => (
    is => 'ro',
    isa => 'WebAppCommon::Util::EnsEMBL',
    lazy_build => 1,
);

sub _build_ensembl{
	my ($self) = @_;
    # Human could be 'Human' or 'GRCh38'
    my $ens_species = ($self->species_name eq 'Mouse' ? 'mouse' : 'human' );
	return WebAppCommon::Util::EnsEMBL->new({ species => $ens_species });
}

has job_id => (
    is  => 'ro',
    isa => 'Str',
    lazy_build => 1,
);

sub _build_job_id{
    return Data::UUID->new->create_str;
}

has file_api => (
    is         => 'ro',
    isa        => 'WebAppCommon::Util::FileAccess',
    lazy_build => 1,
);

sub _build_file_api {
    return WebAppCommon::Util::FileAccess->construct({ server => $ENV{FILE_SERVER} });
}

has job_runner => (
    is         => 'ro',
    isa        => 'WebAppCommon::Util::JobRunner',
    lazy_build => 1,
);

sub _build_job_runner {
    return WebAppCommon::Util::JobRunner->construct({
            server  => $ENV{FARM_SERVER},
            check_return => 0,
            bsub_wrapper => "/nfs/team87/farm3_lims2_vms/conf/run_in_farm3_af11"
        });
}

has workdir => (
    is  => 'ro',
    isa => 'Str',
    lazy_build => 1,
);

sub _build_workdir{
    my ($self) = @_;

    my $library_job_dir = $ENV{WGE_LIBRARY_JOB_DIR}
        or die "No WGE_LIBRARY_JOB_DIR environment variable set";

    my $dir = catdir($library_job_dir, $self->job_id);
    $self->file_api->make_dir($dir);
    return $dir;
}

has design_job => (
    is => 'ro',
    isa => 'WGE::Model::Schema::Result::LibraryDesignJob',
    lazy_build => 1,
);

sub _build_design_job{
    my ($self) = @_;

    # find or create
    my $job = $self->model->schema->resultset('LibraryDesignJob')->find({ id => $self->job_id});

    unless($job){
        $self->user_id
            or die "CrisprLibrary user not specified - cannot create LibraryDesignJob without user";

        my $job_params = {
            species_name  => $self->species_name,
            location_type => $self->location_type,
            within        => $self->within,
            flank_size    => $self->flank_size,
            num_crisprs   => $self->num_crisprs,
        };

        $job = $self->model->schema->resultset('LibraryDesignJob')->create({
            id   => $self->job_id,
            name => $self->job_name,
            params => to_json($job_params),
            target_region_count => 0,
            created_by_id => $self->user_id,
            progress_percent => 0,
        });
    }
    return $job;
}

has crisprs_missing_offs => (
    is => 'rw',
    isa => 'ArrayRef',
    default => sub{ [] },
);

has targets => (
    is => 'rw',
    isa => 'ArrayRef',
    lazy_build => 1,
);

sub _build_targets{
	my ($self) = @_;

    my $coord_methods = {
    	exon       => \&_coords_for_exon,
    	gene       => \&_coords_for_gene,
    	coordinate => \&_coords_for_coord,
    };

    my $get_coords = $coord_methods->{$self->location_type}
        or die "No method to get coordinates for location type ".$self->location_type;

	my @targets;
	# Go through input fh and generate a hash for each target
	# target_name   => (input from file)
	# target_coords => coords computed as required for input type
	my $fh = $self->input_fh;
    seek($fh,0,0);

    my $csv = Text::CSV->new();
    my @inputs;
    while (my $line = $csv->getline($fh)){
        push @inputs, $line->[0];
    }

    my $input_count = scalar @inputs;
    $self->log->debug("Getting coordinates for $input_count library targets");

    # Change the update interval for very small jobs
    if($input_count < $self->update_after_n_items){
        my $interval = ceil( $input_count / 20 );
        $self->log->debug("setting to update progress after $interval items");
        $self->update_after_n_items($interval);
    }

    $self->_update_job({
        target_region_count => $input_count,
        library_design_stage_id => 'find_targets',
        progress_percent => 0,
    });

    my $progress_count = 0;
	foreach my $line (@inputs){
        chomp $line;
        # remove leading/trailing whitespace
        $line =~ s/\A\s+//g;
        $line =~ s/\s+\Z//g;

        my $coords = $get_coords->($self, $line);
        if($coords->{error}){
            $self->_add_warning($line, $coords->{error});
        }

        push @targets, { target_name => $line, target_coords => $coords };
        $progress_count++;
        $self->_update_progress('find_targets',$input_count,$progress_count);
	}
    $self->_update_job({ progress_percent => 100 });

    # Find crisprs as per search params and add to target
    # crisprs => [ $crispr1->as_hash, $crispr2->as_hash, etc  ]

    # First pass finds crispr sites and stores IDs of any crisprs missing off-targets
    $self->_find_crispr_sites(\@targets);

    # Then we generate off targets where missing
    $self->generate_off_targets_on_farm(\@targets);

    # This time repeat the crispr search but sort and store the best crisprs
    return $self->_find_crispr_sites(\@targets, 1);
}

sub _coords_for_exon{
    my ($self, $exon_id) = @_;

    my $coords;

    # Try to get exon coords from wge
    my $exon = $self->model->schema->resultset('Exon')->search({
            ensembl_exon_id => $exon_id,
            'gene.species_id' => $self->species_name,
        },
        {
            prefetch => 'gene',
        })->first;

    if($exon){
        $coords = {
            start => $exon->chr_start,
            end   => $exon->chr_end,
            chr   => $exon->chr_name,
        };
    }
    else{
        # Failing that (we only have exons from canonical transcripts i think)
        # fetch it from ensembl
        $self->log->debug("Searching for exon $exon_id in ensembl");
        $exon = $self->ensembl->exon_adaptor->fetch_by_stable_id($exon_id);
        if($exon){
            $coords = {
            	start => $exon->start,
            	end   => $exon->end,
            	chr   => $exon->seq_region_name,
            };
        }
        else{
            $self->log->warn("Exon $exon_id not found in ensembl");
        	$coords = {
        		error => 'Exon not found',
        	};
        }
    }
    return $coords;
}

sub _coords_for_gene{
    my ($self, $gene_id) = @_;

    my $coords;

    # Try to find gene in WGE
    my $search_params = {
        species_id => $self->species_name,
    };

    my $is_ens_id = 0;
    if($gene_id =~ /^ENS/){
        $search_params->{ensembl_gene_id} = $gene_id;
        $is_ens_id = 1;
    }
    else{
        $search_params->{marker_symbol} = $gene_id;
    }

    my $gene = $self->model->schema->resultset('Gene')->search($search_params)->first;
    if($gene){
        $coords = {
            start => $gene->chr_start,
            end   => $gene->chr_end,
            chr   => $gene->chr_name,
        };
    }
    else{
        # Failing that fetch it from ensembl
        $self->log->debug("Searching for gene $gene_id in ensembl");
        if($is_ens_id){
            $gene = $self->ensembl->gene_adaptor->fetch_by_gene_stable_id($gene_id);
        }
        else{
            my @gene_list = @{ $self->ensembl->gene_adaptor->fetch_all_by_display_label($gene_id) || [] };
            if (@gene_list == 1){
                $gene = $gene_list[0];
            }
        }
        if($gene){
            $coords = {
                start => $gene->start,
                end   => $gene->end,
                chr   => $gene->seq_region_name,
            };
        }
        else{
            $self->log->warn("Gene $gene_id not found in ensembl");
            $coords = {
                error => 'Gene not found',
            };
        }
    }
    return $coords;
}

sub _coords_for_coord{
    my ($self, $coord_string) = @_;

    # accepts chr1:1234-1235
    # or         1:1234-1235

    my $coords;

    # remove any whitespace
    $coord_string =~ s/\s//g;

    my ($chr, $start_end) = split ":", $coord_string;

    unless ($chr and $start_end){
        $coords = {
            error => "Could not parse coordinate string",
        };
        return $coords;
    }

    $chr =~ s/^chr//;

    my ($start, $end) = split "-", $start_end;
    unless ($start and $end){
        $coords = {
            error => "Could not parse start and end coordinates",
        };
        return $coords;
    }

    if($start < $end){
        $coords = {
            start => $start,
            end   => $end,
            chr   => $chr,
        };
    }
    else{
        $self->log->debug("swapping start and end coords");
        $coords = {
            start => $end,
            end   => $start,
            chr   => $chr,
        };
    }

    return $coords;
}

sub _find_crispr_sites{
    my ($self, $targets, $sort_and_store) = @_;

    my $stage = 'find_crisprs';
    if($sort_and_store){
        $stage = 'rank_crisprs';
    }

    my $update_progress = 1;
    if($stage eq 'find_crisprs' and scalar(@{ $self->crisprs_missing_offs })){
        # This is just a check for the number of remaining missing offs
        # We don't want to store the progress of this in the db
        $update_progress = 0;
    }

    my $count = scalar @{ $targets };
    my $progress_count = 0;
    $self->log->debug("Finding crisprs for $count targets");

    $self->_update_job({
        library_design_stage_id => $stage,
        progress_percent        => 0,
    }) if $update_progress;

    # clear list of crisprs missing offs as we might be checking
    # off-target generation status
    $self->crisprs_missing_offs([]);

    foreach my $target (@{ $targets }){
        $progress_count++;
    	# Find crisprs within/flanking target region
        next if $target->{target_coords}->{error};
        my @search_regions;
        my $chr = $target->{target_coords}->{chr};
        if($self->within){
            my $search_start = $target->{target_coords}->{start};
            my $search_end = $target->{target_coords}->{end};
            if($self->flank_size){
                $search_start -= $self->flank_size;
                $search_end += $self->flank_size;
            }
            push @search_regions, {
                start => $search_start,
                end   => $search_end,
                chr   => $chr,
            };
        }
        elsif($self->flank_size){
            push @search_regions, {
                start => $target->{target_coords}->{start} - $self->flank_size,
                end   => $target->{target_coords}->{start},
                chr   => $chr,
            };

            push @search_regions, {
                start => $target->{target_coords}->{end},
                end   => $target->{target_coords}->{end} + $self->flank_size,
                chr   => $chr,
            };
        }
        else{
            die "No CRISPR site search regions requested!";
        }

        if($sort_and_store){
            # Rank them and take first n
            # Store crispr list in targets hash
            $target->{crisprs} = $self->_search_crisprs(\@search_regions, $target->{target_name}, 1);
        }
        else{
            $self->_search_crisprs(\@search_regions, $target->{target_name});
        }


        # Update progress
        $self->_update_progress($stage,$count,$progress_count) if $update_progress;
    }
    $self->_update_job({ progress_percent => 100 }) if $update_progress;

    return $targets;
}

sub _search_crisprs{
    my ($self, $search_regions, $target, $sort_and_store) = @_;
    my $crisprs;

    # Search for any crispr starting in the search region
    # This ignores crisprs which span the region start, but includes those that span the end
    # This may need adapting based on user requirements
    foreach my $region (@{ $search_regions }){
        my $crispr_rs = $self->model->schema->resultset('Crispr')->search({
            chr_name   => $region->{chr},
            chr_start  => { '>' => $region->{start}, '<' => $region->{end} },
            species_id => $self->species_numerical_id,
        });

        foreach my $crispr( $crispr_rs->all ){
            my $crispr_hash = $crispr->as_hash;
            $crisprs->{$crispr->id} = $crispr_hash;
        }
    }
    # crispr ranking ignores crisprs missing off-target summary
    # so we need to generate any missing ones
    my @crisprs_missing_offs = grep { not defined $_->{off_target_summary} } values %$crisprs;
    my $missing_count = @crisprs_missing_offs;
    if($missing_count){
        #$self->log->debug("off-target info missing for $missing_count crisprs");
        push @{ $self->crisprs_missing_offs }, map { $_->{id} } @crisprs_missing_offs;
    }

    if($sort_and_store){
        my @crisprs = score_and_sort_crisprs([ values %$crisprs ]);

        my @best = @crisprs[0..($self->num_crisprs - 1)];
        return \@best;
    }

    return [];
}

sub generate_off_targets_on_farm{
    my ($self, $targets) = @_;

    my $count = scalar( @{ $self->crisprs_missing_offs } );
    $self->log->debug("** generating off-targets on farm for $count crisprs");
    my $user = $self->model->resultset('User')->find({ id => $self->user_id });
    if( !$user || ( $user->library_jobs_restricted && $count > 2000 ) ) {
        die "Too many missing off targets. This requires calculating $count off-targets, "
            . "you may only submit jobs needing up to 2000 at a time.\n";
    }
    if($count){
        $self->_update_job({
            library_design_stage_id => 'off_targets',
            info => "Generating off-targets for $count crispr sites",
            progress_percent => 0,
        });
        my $farm_dir = dir($ENV{'OFF_TARGET_RUN_DIR'})->subdir($self->job_id);
        $self->file_api->make_dir($farm_dir);

        my $id_file = catfile($self->workdir, 'job_ids.txt');
        $self->file_api->post_file_content($id_file, '');

        # split list of offs into batches of 500 (or smaller for short lists)
        my $batch_size = 500;
        if($count < 1000){
            $batch_size = ceil ($count / 5);
        }

        # submit each one to farm basement queue using wge_off_targets.pl script
        my $iter = natatime($batch_size, @{ $self->crisprs_missing_offs });
        my $batch_num = 0;
        while (my @tmp = $iter->() ){
            $batch_num++;

            my $input_file = $farm_dir->file("ot_input_list_$batch_num.txt");
            $self->file_api->post_file_content("$input_file", (join "\n", @tmp));

            my $out_file = $farm_dir->file("ot_job_$batch_num.out");
            my $err_file = $farm_dir->file("ot_job_$batch_num.err");

            my $cmd = ['perl',$ENV{OFF_TARGET_SCRIPT}, $self->species_name, $input_file];
            my $output = $self->job_runner->submit({
                out_file => $out_file,
                err_file => $err_file,
                cmd      => $cmd,
                group    => 'team87-grp', # change this to team229-grp when available
                memory_required => 3000,
            });

            $self->log->debug("command output: $output");
            my ($job_id) = ( $output =~ /(\d+)/g );
            $self->log->debug("adding bjob ID $job_id to file");
            $self->file_api->append_file_content($id_file, "$job_id\n");
        }

        # every 10 mins repeat the check for missing offs, update progress percent
        # only continue when no more offs are missing
        while(1){
            sleep(600);
            $self->_find_crispr_sites($targets);
            my $missing_count = scalar( @{ $self->crisprs_missing_offs } );
            if($missing_count){
                $self->log->debug("Still have $missing_count crisprs missing offs");
                my $off_targets_done = $count - $missing_count;
                $self->_force_update_progress('off_targets', $count, $off_targets_done);
            }
            else{
                # All done!
                $self->file_api->delete_file($id_file);
                return;
            }
        }
    }

    return;
}

sub write_csv_data_to_file{
    my ($self, $filename) = @_;

    my $file = catfile($self->workdir, $filename);
    my $contents = q//;
    open my $fh, '>', \$contents or die "Could not open string for writing - $!";

    my $extra_fields = [ qw(search_region_name search_region_chromosome search_region_start search_region_end) ];

    # print header to file
    print {$fh} join "\t", @{ format_crisprs_for_csv_header($extra_fields) };
    print {$fh} "\n";

    foreach my $target (@{ $self->targets }){
        if($target->{target_coords}->{error}){
            #push @all_data, { target_name => $target->{target_name} };
            next;
        }
        foreach my $crispr (@{ $target->{crisprs} }){
            if($crispr){
                my %crispr_info = %{ $crispr };
                $crispr_info{search_region_name} = $target->{target_name};
                $crispr_info{search_region_chromosome} = $target->{target_coords}->{chr};
                $crispr_info{search_region_start} = $target->{target_coords}->{start};
                $crispr_info{search_region_end} = $target->{target_coords}->{end};

                print {$fh} join "\t", @{ format_crisprs_for_csv_data(\%crispr_info, $extra_fields) };
                print {$fh} "\n";
            }
            else{
                $self->log->warn("Not enough crisprs found for target ".$target->{target_name});
            }
        }
    }

    close $fh;
    $self->file_api->post_file_content($file, $contents);

    $self->_update_job({ complete => 1, results_file => "$file" });

    return $file;
}

sub write_input_data_to_file{
    my ($self, $filename) = @_;

    my $file = catfile($self->workdir, $filename);

    my $contents;
    open my $out_fh, '>', \$contents or die "Could not open string for writing - $!";

    my $in_fh = $self->input_fh;
    seek($in_fh,0,0);

    foreach my $line(<$in_fh>){
        print {$out_fh} $line;
    }
    
    close $out_fh;
    $self->file_api->post_file_content($file, $contents);
    $self->_update_job({ input_file => "$file" });

    return $file;
}

# Because _update_progress will only make changes every n items
# but when checking off-target generation we need to update every 10 minutes
# regardless of the number of items
sub _force_update_progress{
    my ($self, $stage, $total, $progress) = @_;
    return $self->_update_progress($stage,$total,$progress,1);
}

sub _update_progress{
    my ($self, $stage, $total, $progress, $force) = @_;

    # Do update every n records if the progress to db flag is set
    if($self->write_progress_to_db){
        if( $force or ($progress % $self->update_after_n_items) == 0 ){
            my $percent  = ceil( ($progress / $total) * 100 );

            # We want the row's modification time to update even
            # if progress percent has not advanced
            $self->design_job->make_column_dirty('progress_percent');

            $self->design_job->update({
                library_design_stage_id => $stage,
                progress_percent        => $percent,
            });
            $self->log->debug("Progress updated to $stage $percent%");
        }
    }
    return;
}

sub _add_warning{
    my ($self, $target_name, $warning) = @_;

    if($self->write_progress_to_db){
        my $warning_from_db = $self->design_job->warning // "" ;
        my $new_warning = $warning_from_db."<br>$target_name: ".$warning;
        $self->design_job->update({ warning => $new_warning });
    }
    return;
}

# Wrap update to check write to db flag before attempting to update
sub _update_job{
    my ($self, $update_params) = @_;

    if($self->write_progress_to_db){
        $self->design_job->update($update_params);
    }
    return;
}

1;