=pod

=head1 NAME

Geo::OGC::Service::SOS - Perl extension for sensor observation service

=head1 SYNOPSIS

The process_request method of this module is called by the
Geo::OGC::Service framework.

=head1 DESCRIPTION

This module aims to provide the operations defined by the Open
Geospatial Consortium's Sensor Observation Service standard.

This module is a plugin for the Geo::OGC::Service framework.

=head2 EXPORT

None by default.

=head2 METHODS

=cut

package Geo::OGC::Service::SOS;

use 5.010000; # say // and //=
use feature "switch";
use Carp;
use File::Basename;
use Modern::Perl;
use Capture::Tiny ':all';
use Clone 'clone';
use JSON;
use DBI;
use Geo::GDAL;
use HTTP::Date;
use File::MkTemp;

use Data::Dumper;
use XML::LibXML::PrettyPrint;

use Geo::OGC::Service;
use vars qw(@ISA);
push @ISA, qw(Geo::OGC::Service::Common);

our $VERSION = '0.01';

=pod

=head3 process_request

The entry method into this service. Fails unless the request is well known.

=cut

sub process_request {
    my ($self, $responder) = @_;
    $self->parse_request;
    $self->{debug} = $self->{config}{debug} // 0;
    $self->{responder} = $responder;
    if ($self->{parameters}{debug}) {
        $self->error({ 
            debug => { 
                config => $self->{config}, 
                parameters => $self->{parameters}, 
                env => $self->{env},
                request => $self->{request} 
            } });
        return;
    }
    if ($self->{debug}) {
        $self->log({ request => $self->{request}, parameters => $self->{parameters} });
        my $parser = XML::LibXML->new(no_blanks => 1);
        my $pp = XML::LibXML::PrettyPrint->new(indent_string => "  ");
        if ($self->{posted}) {
            my $dom = $parser->load_xml(string => $self->{posted});
            $pp->pretty_print($dom); # modified in-place
            say STDERR "posted:\n",$dom->toString;
        }
        if ($self->{filter}) {
            my $dom = $parser->load_xml(string => $self->{filter});
            $pp->pretty_print($dom); # modified in-place
            say STDERR "filter:\n",$dom->toString;
        }
    }
    for ($self->{request}{request} // '') {
        if (/^GetCapabilities/ or /^capabilities/) { $self->GetCapabilities() }
        elsif (/^DescribeFeatureType/)             { $self->DescribeFeatureType() }
        elsif (/^GetFeature/)                      { $self->GetFeature() }
        elsif (/^Transaction/)                     { $self->Transaction() }
        elsif (/^$/)                               { 
            $self->error({ exceptionCode => 'MissingParameterValue',
                           locator => 'request' }) }
        else                                       { 
            $self->error({ exceptionCode => 'InvalidParameterValue',
                           locator => 'request',
                           ExceptionText => "$self->{parameters}{request} is not a known request" }) }
    }
}

=pod

=head3 GetCapabilities

Service the GetCapabilities request. The configuration JSON is used to
control the contents of the reply. The config contains root keys, which
are either simple or complex. The simple root keys are

 Key                 Default             Comment
 ---                 -------             -------
 version             2.0.0
 Title               SOS Server
 resource                                required
 ServiceTypeVersion
 AcceptVersions      2.0.0,1.1.0,1.0.0
 Transaction                             optional

=cut

sub GetCapabilities {
    my ($self) = @_;

    my $writer = Geo::OGC::Service::XMLWriter::Caching->new();

    my %inspireNameSpace = (
        'xmlns:inspire_dls' => "http://inspire.ec.europa.eu/schemas/inspire_dls/1.0",
        'xmlns:inspire_common' => "http://inspire.ec.europa.eu/schemas/common/1.0"
        );
    my $inspireSchemaLocations = 
        'http://inspire.ec.europa.eu/schemas/common/1.0 '.
        'http://inspire.ec.europa.eu/schemas/common/1.0/common.xsd '.
        'http://inspire.ec.europa.eu/schemas/inspire_dls/1.0 '.
        'http://inspire.ec.europa.eu/schemas/inspire_dls/1.0/inspire_dls.xsd';
    
    my %ns;
    if ($self->{version} eq '2.0.0') {
        %ns = (
            xmlns => "http://www.opengis.net/wfs/2.0" ,
            'xmlns:gml' => "http://schemas.opengis.net/gml",
            'xmlns:wfs' => "http://www.opengis.net/wfs/2.0",
            'xmlns:ows' => "http://www.opengis.net/ows/1.1",
            'xmlns:xlink' => "http://www.w3.org/1999/xlink",
            'xmlns:xsi' => "http://www.w3.org/2001/XMLSchema-instance",
            'xmlns:fes' => "http://www.opengis.net/fes/2.0",
            'xmlns:xs' => "http://www.w3.org/2001/XMLSchema",
            'xmlns:srv' => "http://schemas.opengis.net/iso/19139/20060504/srv/srv.xsd",
            'xmlns:gmd' => "http://schemas.opengis.net/iso/19139/20060504/gmd/gmd.xsd",
            'xmlns:gco' => "http://schemas.opengis.net/iso/19139/20060504/gco/gco.xsd",
            'xsi:schemaLocation' => "http://www.opengis.net/wfs/2.0 http://schemas.opengis.net/wfs/2.0/wfs.xsd",
            );
        # updateSequence="260" ?
    } else {
        %ns = (
            xmlns => "http://www.opengis.net/wfs",
            'xmlns:gml' => "http://www.opengis.net/gml",
            'xmlns:wfs' => "http://www.opengis.net/wfs",
            'xmlns:ows' => "http://www.opengis.net/ows",
            'xmlns:xlink' => "http://www.w3.org/1999/xlink",
            'xmlns:xsi' => "http://www.w3.org/2001/XMLSchema-instance",
            'xmlns:ogc' => "http://www.opengis.net/ogc",
            'xsi:schemaLocation' => "http://www.opengis.net/wfs http://schemas.opengis.net/wfs/1.1.0/wfs.xsd"
            );
    }
    $ns{version} = $self->{version};

    $writer->open_element('wfs:WFS_Capabilities', \%ns);
    $self->DescribeService($writer);
    $self->OperationsMetadata($writer);
    $self->FeatureTypeList($writer);
    $self->Filter_Capabilities($writer);
    $writer->close_element;
    $writer->stream($self->{responder});
}

sub OperationsMetadata  {
    my ($self, $writer) = @_;
    $writer->open_element('ows:OperationsMetadata');
    my @versions = split /,/, $self->{config}{AcceptVersions} // '2.0.0,1.1.0,1.0.0';
    $self->Operation($writer, 'GetCapabilities',
                     { Get => 1, Post => 1 },
                     [{service => ['WFS']}, 
                      {AcceptVersions => \@versions}, 
                      {AcceptFormats => ['text/xml']}]);
    $self->Operation($writer, 'DescribeFeatureType', 
                     { Get => 1, Post => 1 },
                     [{outputFormat => [sort keys %OutputFormats]}]);
    $self->Operation($writer, 'GetFeature',
                     { Get => 1, Post => 1 },
                     [{resultType => ['results']}, {outputFormat => [sort keys %OutputFormats]}]);
    $self->Operation($writer, 'Transaction',
                     { Get => 1, Post => 1 },
                     [{inputFormat => ['text/xml; subtype=gml/3.1.1']}, 
                      {idgen => ['GenerateNew','UseExisting','ReplaceDuplicate']},
                      {releaseAction => ['ALL','SOME']}
                     ]);
    # constraints
    my %constraints = (
        ImplementsBasicWFS => 1,
        ImplementsTransactionalWFS => 1,
        ImplementsLockingWFS => 0,
        KVPEncoding => 1,
        XMLEncoding => 1,
        SOAPEncoding => 0,
        ImplementsInheritance => 0,
        ImplementsRemoteResolve => 0,
        ImplementsResultPaging => 0,
        ImplementsStandardJoins => 1,
        ImplementsSpatialJoins => 1,
        ImplementsTemporalJoins => 1,
        ImplementsFeatureVersioning => 0,
        ManageStoredQueries => 0,
        PagingIsTransactionSafe => 1,
        );
    for my $key (keys %constraints) {
        $writer->element('ows:Constraint', {name => $key}, 
                         [['ows:NoValues'], 
                          ['ows:DefaultValue' => $constraints{$key} ? 'TRUE' : 'FALSE']]);
    }
    $writer->element('ows:Constraint', {name => 'QueryExpressions'}, 
                     ['ows:AllowedValues' => ['ows:Value' => 'wfs:Query']]);
    $writer->close_element;
}

sub Filter_Capabilities  {
    my ($self, $writer) = @_;
    my $ns = $self->{version} eq '2.0.0' ? 'fes' : 'ogc';
    $writer->open_element($ns.':Filter_Capabilities');

    # Conformance
    my %Constraints = ( 
        ImplementsQuery => [['ows:NoValues'], ['ows:DefaultValue' => 'TRUE']],
        ImplementsAdHocQuery => [['ows:NoValues'], ['ows:DefaultValue' => 'TRUE']],
        ImplementsFunctions => [['ows:NoValues'], ['ows:DefaultValue' => 'TRUE']],
        ImplementsMinStandardFilter => [['ows:NoValues'], ['ows:DefaultValue' => 'TRUE']],
        ImplementsStandardFilter => [['ows:NoValues'], ['ows:DefaultValue' => 'FALSE']],
        ImplementsMinSpatialFilter => [['ows:NoValues'], ['ows:DefaultValue' => 'TRUE']],
        ImplementsSpatialFilter => [['ows:NoValues'], ['ows:DefaultValue' => 'FALSE']],
        ImplementsMinTemporalFilter => [['ows:NoValues'], ['ows:DefaultValue' => 'TRUE']],
        ImplementsTemporalFilter => [['ows:NoValues'], ['ows:DefaultValue' => 'TRUE']],
        ImplementsVersionNav => [['ows:NoValues'], ['ows:DefaultValue' => 'FALSE']],
        ImplementsSorting => [['ows:AllowedValues' => [['ows:Value' => 'ASC'], ['ows:Value' => 'DESC']]], 
                              ['ows:DefaultValue' => 'ASC']],
        ImplementsExtendedOperators => [['ows:NoValues'], ['ows:DefaultValue' => 'FALSE']],
        );
    my @c;
    for my $key (keys %Constraints) {
        push @c, [$ns.':Constraint', {name=>$key}, $Constraints{$key}];
    }
    $writer->element($ns.':Conformance', \@c);

    my @ids;
    if ($ns eq 'ogc') {
        @ids = ([$ns.':FID']);
    } else {
        @ids = (['fes:ResourceIdentifier', {name => 'fes:ResourceId'}]);
    }
    $writer->element($ns.':Id_Capabilities', \@ids);

    my @operators = ();    
    for my $o (qw/LessThan GreaterThan LessThanOrEqualTo GreaterThanOrEqualTo EqualTo NotEqualTo Like Between Null/) {
        if ($ns eq 'ogc') {
            push @operators, [$ns.':ComparisonOperator', 'PropertyIs'.$o];
        } else {
            push @operators, [$ns.':ComparisonOperator', { name => 'PropertyIs'.$o}];
        }
    }
    $writer->element($ns.':Scalar_Capabilities', 
                [[$ns.':LogicalOperators'], # empty ?
                 [$ns.':ComparisonOperators', \@operators]]);

    my @operands = ();
    for my $o (keys %gml_geometry_type) {
        if ($ns eq 'ogc') {
            push @operands, [$ns.':GeometryOperand', 'gml:'.$o];
        } else {
            push @operands, [$ns.':GeometryOperand', { name => 'gml:'.$o }];
        }
    }
    @operators = ();
    my @op = keys %spatial2op;
    push @op, (qw/DWithin BBOX/);
    for my $o (@op) {
        push @operators, [$ns.':SpatialOperator', { name => $o }];
    }
    $writer->element($ns.':Spatial_Capabilities', 
                [[$ns.':GeometryOperands', \@operands],
                 [$ns.':SpatialOperators', \@operators]]);

    # Temporal_Capabilities

    @operands = ();
    for my $o (qw/TimeInstant TimePeriod/) {
        if ($ns eq 'ogc') {
            push @operands, [$ns.':GeometryOperand', 'gml:'.$o];
        } else {
            push @operands, [$ns.':GeometryOperand', { name => 'gml:'.$o }];
        }
    }
    @operators = ();
    @op = keys %temporal_operators;
    for my $o (@op) {
        push @operators, [$ns.':TemporalOperator', { name => $o }];
    }
    $writer->element($ns.':Temporal_Capabilities', 
                     [[$ns.':TemporalOperands', \@operands],
                      [$ns.':TemporalOperators', \@operators]]);

    # Functions
    
    my @functions;
    for my $f (sort keys %functions) {
        my @args = ();
        my $args = $functions{$f}[1];
        for my $arg (@$args) {
            push @args, [$ns.':Argument', { name => $arg->[0]}, [$ns.':Type' => $arg->[1]]];
        }
        push @functions, [$ns.':Function', { name => $f }, 
                          [[$ns.':Returns' => $functions{$f}[0]] ,[$ns.':Arguments' => \@args]]];
    }
    $writer->element($ns.':Functions', \@functions);
    
    $writer->close_element;
}

=pod

=head3 DescribeFeatureType

Service the DescribeFeatureType request.

=cut

sub DescribeFeatureType {
    my ($self) = @_;

    my @typenames;
    for my $query (@{$self->{request}{queries}}) {
        push @typenames, split(/\s*,\s*/, $query->{typename});
    }

    unless (@typenames) {
        $self->error({ exceptionCode => 'MissingParameterValue',
                       locator => 'typeName' });
        return;
    }
    
    my %types;

    for my $name (@typenames) {
        $types{$name} = $self->feature_type($name);
        unless ($types{$name}) {
            $self->error({ exceptionCode => 'InvalidParameterValue',
                           locator => 'typeName',
                           ExceptionText => "Type '$name' is not available" });
            return;
        }
    }

    my $writer = Geo::OGC::Service::XMLWriter::Caching->new();
    $writer->open_element(
        'schema', 
        { version => '0.1',
          targetNamespace => "http://mapserver.gis.umn.edu/mapserver",
          xmlns => "http://www.w3.org/2001/XMLSchema",
          'xmlns:ogr' => "http://ogr.maptools.org/",
          'xmlns:ogc' => "http://www.opengis.net/ogc",
          'xmlns:xsd' => "http://www.w3.org/2001/XMLSchema",
          'xmlns:gml' => "http://www.opengis.net/gml",
          elementFormDefault => "qualified" });
    $writer->element(
        'import', 
        { namespace => "http://www.opengis.net/gml",
          schemaLocation => "http://schemas.opengis.net/gml/2.1.2/feature.xsd" } );

    for my $name (sort keys %types) {
        my $type = $types{$name};
        next if $type->{"gml:id"} && $type->{Name} eq $type->{"gml:id"};

        my ($pseudo_credentials) = pseudo_credentials($type);
        my @elements;
        for my $property (keys %{$type->{Schema}}) {

            next if $pseudo_credentials->{$property};

            my $minOccurs = 0;
            push @elements, ['element', 
                             { name => $type->{Schema}{$property}{out_name},
                               type => $type->{Schema}{$property}{out_type},
                               minOccurs => "$minOccurs",
                               maxOccurs => "1" } ];

        }
        $writer->element(
            'complexType', {name => $type->{Name}.'Type'},
            ['complexContent', 
             ['extension', { base => 'gml:AbstractFeatureType' },
              ['sequence', \@elements
              ]]]);
        $writer->element(
            'element', { name => $type->{Name},
                         type => 'ogr:'.$type->{Name}.'Type',
                         substitutionGroup => 'gml:_Feature' } );
    }
    
    $writer->close_element();
    $writer->stream($self->{responder});
}

1;
__END__

=head1 SEE ALSO

Discuss this module on the Geo-perl email list.

L<https://list.hut.fi/mailman/listinfo/geo-perl>

For the SOS standard see 

L<http://www.opengeospatial.org/standards/sos>

=head1 REPOSITORY

L<https://github.com/ajolma/Geo-OGC-Service-SOS>

=head1 AUTHOR

Ari Jolma, E<lt>ari.jolma at gmail.comE<gt>

=head1 COPYRIGHT AND LICENSE

Copyright (C) 2015 by Ari Jolma

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.22.0 or,
at your option, any later version of Perl 5 you may have available.

=cut
