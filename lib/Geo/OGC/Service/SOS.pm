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
use Geo::OGC::Service::Filter ':all';
use vars qw(@ISA);
push @ISA, qw(Geo::OGC::Service::Filter);

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
        if (/^GetCapabilities/)         { $self->GetCapabilities() }
        elsif (/^DescribeSensor/)       { $self->DescribeSensor() }
        elsif (/^GetObservation/)       { $self->GetObservation() }
        elsif (/^GetFeatureOfInterest/) { $self->GetFeatureOfInterest() }
        elsif (/^GetObservationById/)   { $self->GetObservationById() }
        elsif (/^InsertSensor/)         { $self->InsertSensor() }
        elsif (/^DeleteSensor/)         { $self->DeleteSensor() }
        elsif (/^InsertObservation/)    { $self->InsertObservation() }
        elsif (/^InsertResultTemplate/) { $self->InsertResultTemplate() }
        elsif (/^InsertResult/)         { $self->InsertResult() }
        elsif (/^GetResultTemplate/)    { $self->GetResultTemplate() }
        elsif (/^GetResult/)            { $self->GetResult() }
        elsif (/^$/)                    { 
            $self->error({ exceptionCode => 'MissingParameterValue',
                           locator => 'request' }) }
        else                            { 
            $self->error({ exceptionCode => 'InvalidParameterValue',
                           locator => 'request',
                           ExceptionText => "$self->{request}{request} is not a known request" }) }
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

    my %ns;
    if ($self->{version} eq '2.0.0') {
        %ns = (
            xmlns => "http://www.opengis.net/sos/2.0" ,
            'xmlns:sos' => "http://schemas.opengis.net/sos/2.0",
            'xmlns:gml' => "http://schemas.opengis.net/gml",
            'xmlns:ows' => "http://www.opengis.net/ows/1.1",
            'xmlns:om' => "http://www.opengis.net/om/1.0",
            'xmlns:xlink' => "http://www.w3.org/1999/xlink",
            'xmlns:xsi' => "http://www.w3.org/2001/XMLSchema-instance",
            'xmlns:fes' => "http://www.opengis.net/fes/2.0",
            'xmlns:xs' => "http://www.w3.org/2001/XMLSchema",
            'xmlns:srv' => "http://schemas.opengis.net/iso/19139/20060504/srv/srv.xsd",
            'xmlns:gmd' => "http://schemas.opengis.net/iso/19139/20060504/gmd/gmd.xsd",
            'xmlns:gco' => "http://schemas.opengis.net/iso/19139/20060504/gco/gco.xsd",
            'xsi:schemaLocation' => "http://www.opengis.net/sos/2.0 http://schemas.opengis.net/sos/2.0.0/sosAll.xsd",
            );
        # updateSequence="260" ?
    } else {
        %ns = (
            xmlns => "http://www.opengis.net/sos/1.0",
            'xmlns:sos' => "http://www.opengis.net/sos/1.0",
            'xmlns:gml' => "http://www.opengis.net/gml",
            'xmlns:ows' => "http://www.opengis.net/ows",
            'xmlns:om' => "http://www.opengis.net/om/1.0",
            'xmlns:xlink' => "http://www.w3.org/1999/xlink",
            'xmlns:xsi' => "http://www.w3.org/2001/XMLSchema-instance",
            'xmlns:ogc' => "http://www.opengis.net/ogc",
            'xsi:schemaLocation' => "http://www.opengis.net/sos/1.0 http://schemas.opengis.net/sos/1.0.0/sosAll.xsd"
            );
    }
    $ns{version} = $self->{version};

    $writer->open_element('sos:Capabilities', \%ns);
    $self->DescribeService($writer);
    $self->OperationsMetadata($writer);
    $self->ObservationOfferingList($writer);
    $self->Filter_Capabilities($writer);
    $writer->close_element;
    $writer->stream($self->{responder});
}

sub OperationsMetadata  {
    my ($self, $writer) = @_;
    $writer->open_element('ows:OperationsMetadata');
    
    $self->Operation($writer, 'GetCapabilities', { Get => 1, Post => 1 },
                     [ {Sections => [AllowedValues => 
                                     [qw/ServiceIdentification ServiceProvider OperationsMetadata Contents All/]]}
                     ]);
    
    $self->Operation($writer, 'DescribeSensor', { Get => 1, Post => 1 },
                     [ {outputFormat => [AllowedValues => ['text/xml;subtype="sensorML"']]}
                     ]);
    
    $self->Operation($writer, 'GetObservation', { Get => 1, Post => 1 },
                     [ {offering => [AllowedValues => ['stationid']]},
                       {observedProperty => [AllowedValues => ['water_temperature']]},
                       {responseFormat => [AllowedValues => ['text/tab-separated-values']]},
                       {eventTime => [AllowedValues => ['eventTime element']]},
                       {procedure => [AllowedValues => ['procedure element']]},
                       {result => [AllowedValues => ['']]},
                       {unit => [AllowedValues => ['Meters', 'Celsius']]},
                       {timeZone => [AllowedValues => ['EET']]},
                       {epoch => [AllowedValues => ['']]},
                       {dataType => [AllowedValues => ['']]},
                     ]);

    my @versions = split /,/, $self->{config}{AcceptVersions} // '2.0.0,1.0.0';

    $writer->element($self->Parameter(service => [AllowedValues => ['SOS']]));
    $writer->element($self->Parameter(version => [AllowedValues => \@versions]));
    $writer->element('ows:ExtendedCapabilities' => '');
    
    $writer->close_element;
}

sub ObservationOfferingList {
    my ($self, $writer) = @_;
    $writer->open_element('sos:Contents');
    $writer->open_element('sos:ObservationOfferingList');

    for my $o ($self->offerings) {
        my @attr = (['gml:description' => $o->{descr}],
                    ['gml:name' => $o->{name}],
                    ['gml:boundedBy' => $o->{env}],
                    ['sos:time' => $o->{time}],
                    ['sos:procedure' => $o->{proc}]);
        for my $p (@{$o->{prop}}) {
            push @attr, ['sos:observedProperty' => $p];
        }
        for my $p (@{$o->{foi}}) {
            push @attr, ['sos:featureOfInterest' => $p];
        }
        for my $p (@{$o->{format}}) {
            push @attr, ['sos:responseFormat' => $p];
        }
        push @attr, ['sos:resultModel' => $o->{model}];
        push @attr, ['sos:responseMode' => $o->{mode}];
        $writer->element('sos:ObservationOffering' => {'gml:id' => $o->{id}}, \@attr);
    }

    $writer->close_element;
    $writer->close_element;
}

=pod

=head3 DescribeSensor

=cut

sub DescribeSensor {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

=pod

=head3 GetObservation

=cut

sub GetObservation {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

=pod

=head3 GetFeatureOfInterest

=cut

sub GetFeatureOfInterest {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

=pod

=head3 GetObservationById

=cut

sub GetObservationById {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

=pod

=head3 InsertSensor

=cut

sub InsertSensor {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

=pod

=head3 DeleteSensor

=cut

sub DeleteSensor {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

=pod

=head3 InsertObservation

=cut

sub InsertObservation {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

=pod

=head3 InsertResultTemplate

=cut

sub InsertResultTemplate {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

=pod

=head3 InsertResult

=cut

sub InsertResult {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

=pod

=head3 GetResultTemplate

=cut

sub GetResultTemplate {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

=pod

=head3 GetResult

=cut

sub GetResult {
    my ($self) = @_;
    $self->error({ exceptionCode => 'NotImplemented',
                   locator => 'request',
                   ExceptionText => "$self->{request}{request} is not yet implemented." })
}

sub parse_request {
    my $self = shift;
    if ($self->{posted}) {
        $self->{request} = ogc_request($self->{posted});
    } elsif ($self->{parameters}) {
        $self->{request} = {
            request => $self->{parameters}{request},
            version => $self->{parameters}{version},
            outputformat => $self->{parameters}{outputformat}
        };
    }

    my %defaults = (
        version => '2.0.0',
        Title => 'SOS Server',
        );
    for my $key (keys %defaults) {
        $self->{config}{$key} //= $defaults{$key};
    }
    for my $key (qw/resource ServiceTypeVersion/) {
        $self->{config}{$key} //= '';
    }
    # version negotiation
    $self->{version} = 
        latest_version($self->{parameters}{acceptversions}) // # not in standard, QGIS WFS 2.0 Client uses
        $self->{request}{version} // 
        $self->{config}{version};
}

sub offerings {
    my $self = shift;
    my @offerings;

    my $o = {
        id => 0,
        descr => 'Description',
        name => 'Name',
        env => 'GML Envelope here',
        time => 'Timeperiod of measurements?',
        proc => 'Procedure how this was done',
        prop => ['Observed property 1', 'Observed property 2'],
        foi => ['Feature of interest 1', 'feature of interest 2'],
        'format' => ['response format 1', 'response format 2'],
        model => 'om:Result model here',
        mode => 'response mode?',
    };
    push @offerings, $o;
    return @offerings;
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
