% Excel class for building a struct from data extracted from a template spreadsheet
%
% Copyright (C) 2019, Raytheon BBN Technologies and contributors listed
% in the AUTHORS file in EPV distribution's top directory.
%
% This file is part of the Excel Process Validator package, and is distributed
% under the terms of the GNU General Public License, with a linking
% exception, as described in the file LICENSE in the BBN Flow Cytometry
% package distribution's top directory.

classdef TemplateExtraction
    methods(Static)
        % Constuctor with filepath of template and optional coordinates
        % property as inputs
        function extracted = extract(file, template)
            % Make sure the file exists
            if ~exist(file,'file')
                EPVSession.error('TemplateExtraction','MissingFile','Could not find Excel file %s',file);
            end
            EPVSession.succeed('TemplateExtraction','FoundFile','Found excel file %s',file);
            
            % validate that template is intact
            [~,cache] = TemplateExtraction.checkTemplateIntegrity(file, template);
            
            % read the variables of the template
            extracted = TemplateExtraction.retrieveVariables(file, template, cache);
        end
        
    end
    
    methods(Static,Hidden)
        function extracted = retrieveVariables(file, template, cache)
            extracted = struct();
            failed = false;
            for i=1:numel(template.variables)
                try 
                    var = template.variables{i};
                    % get the type of the variable
                    if numel(var)<4, type = 'number'; else type = var{4}; end;
                    % TODO: figure out how to deal with the fact that octave strips blank rows on read, thus shrinking the size of the range being read
                    raw = TemplateExtraction.readExcelFromCache(cache,var{2},var{3});
                    % check what size the raw should be, and expand if needed (for octave, which strips blank rows)
                    block_size = TemplateExtraction.excelRangeSize(var{3});
                    read_size = size(raw);
                    %fprintf('Range %s is %i by %i\n',var{3},block_size(1),block_size(2));
                    if numel(raw) < prod(block_size)
                        %fprintf('Resizing %s from %ix%i to %ix%i\n',var{1},size(raw,1),size(raw,2),block_size(1),block_size(2));
                        for r = (read_size(1)+1):block_size(1),
                            for c = 1:block_size(2),
                                raw{r,c} = nan;
                            end
                        end
                        for r = 1:block_size(1),
                            for c = (read_size(2)+1):block_size(2),
                                raw{r,c} = nan;
                            end
                        end
                    end
                    % turn empty cells into NaNs (for octave)
                    for j=1:numel(raw), if isempty(raw{j}), raw{j} = NaN; end; end;
                    switch type
                        case 'number'
                            converted = zeros(size(raw));
                            for j=1:numel(raw), 
                                if isnumeric(raw{j}), converted(j)=raw{j}; 
                                % check for the various non-numeric placeholders
                                elseif strcmp(raw{j},'---'), converted(j)=NaN;
                                elseif strcmp(raw{j},'#VALUE!'), converted(j)=NaN;
                                elseif strcmp(raw{j},'#DIV/0!'), converted(j)=NaN;
                                elseif strcmp(raw{j},'Overflow'), converted(j)=NaN;
                                else
                                    EPVSession.warn('TemplateExtraction','NonNumericValue','Numeric variable %s from sheet ''%s'' range %s contains non-numeric value ''%s'' (permitted non-numeric values are: ---, #VALUE!, #DIV/0!, Overflow)',var{1},var{2},var{3},raw{j});
                                    failed = true;
                                end;
                            end
                        case 'string'
                            converted = cell(size(raw));
                            for j=1:numel(raw), 
                                if isnumeric(raw{j}), converted{j}=num2str(raw{j}); 
                                else converted{j}=raw{j};  
                                end;
                            end
                        otherwise
                            EPVSession.error('TemplateExtraction','BadRangeType','Variable %s from sheet ''%s'' range %s has unknown type ''%s''',var{1},var{2},var{3},type);
                    end
                    extracted.(var{1}) = converted;
                catch e
                    EPVSession.warn('TemplateExtraction','FailedRangeRead','Unable to read %s variable %s from sheet ''%s'' range %s',type,var{1},var{2},var{3});
                    failed = true;
                end
            end
            if failed,
                EPVSession.error('TemplateExtraction','FailedExtraction','Some variables were unable to be read');
            end
            EPVSession.succeed('TemplateExtraction','Extraction','All variables were extracted');
        end
        
        function [sheets, cache] = checkTemplateIntegrity(file, template)
            % confirm all sheets are present
            var_sheets = cellfun(@(x)(x{2}),template.variables,'UniformOutput',0);
            fix_sheets = cellfun(@(x)(x{1}),template.fixed_values,'UniformOutput',0);
            sheets = unique([var_sheets; fix_sheets]);
            
            missing_sheets = '';
            cache = cell(numel(sheets),2);
            for i=1:numel(sheets),
                try
                    cache{i,1} = sheets{i};
                    [~,~,cache{i,2}] = xlsread(file, sheets{i}); % as a side effect, cache what comes out
                catch
                    if isempty(missing_sheets), connector = ''; else connector = ', '; end;
                    missing_sheets = sprintf('%s%s''%s''',missing_sheets,connector,sheets{i});
                end
            end
            if ~isempty(missing_sheets)
                EPVSession.error('TemplateExtraction','MissingSheets','In %s, could not find expected sheet(s): %s',file, missing_sheets);
            end
            EPVSession.succeed('TemplateExtraction','ValidSheets','All expected sheets are present');
            
            %%% confirm that all expected fixed sections of the sheets match the blank template file
            % first, load the blank
            if ~exist(template.blank_file,'file')
                EPVSession.error('TemplateExtraction','MissingTemplateFile','Internal error: missing blank template file %s',template.blank_file);
            end
            blank_cache = cache;
            for i=1:numel(sheets),
                try
                    [~,~,blank_cache{i,2}] = xlsread(template.blank_file, sheets{i}); % read the blank sheets for comparison
                catch
                EPVSession.error('TemplateExtraction','MissingTemplateSheet','Internal error: blank template file missing sheet %s',sheets{i});
                end
            end
            
            failed = false;
            for i=1:numel(template.fixed_values)
                sheet = template.fixed_values{i}{1};
                ranges = template.fixed_values{i}(2:end);
                for j=1:numel(ranges)
                    blank_raw = TemplateExtraction.readExcelFromCache(blank_cache,sheet,ranges{j});
                    raw = TemplateExtraction.readExcelFromCache(cache,sheet,ranges{j});
                    if ~TemplateExtraction.excelRangeEqual(raw,blank_raw)
                        failed = true;
                        EPVSession.warn('TemplateExtraction','ModifiedTemplateRange','Template appears to have been modified: sheet ''%s'' range %s does not match blank',sheet,ranges{j});
                    end
                end
            end
            if failed,
                EPVSession.error('TemplateExtraction','ModifiedTemplate','Template appears to have been modified - some ranges that are expected to be fixed do no match');
            end
            EPVSession.succeed('TemplateExtraction','ValidTemplate','Template appears to be intact');
        end
        
        % Internal check to see if two number/string regions are identical
        function same = excelRangeEqual(raw1,raw2)
            same = false;
            % sizes must be the same
            if ~isempty(find(size(raw1)~=size(raw2),1)), return; end;
            % every element must be the same
            for i=1:numel(raw1)
                if isempty(raw1{i}) || isempty(raw2{i}) % handle emptiness separately, since tests don't work right 
                    if ~isempty(raw1{i}) && isempty(raw2{i}), return; end;
                elseif isnumeric(raw1{i}) && isnumeric(raw2{i})
                    if isnan(raw1{i}) && isnan(raw2{i}), continue; end; % nan's aren't ==, but match
                    if raw1{i} ~= raw2{i}, return; end;
                elseif ischar(raw1{i}) && ischar(raw2{i})
                    if ~strcmp(raw1{i},raw2{i}), return; end;
                else % mismatched types
                    return;
                end
            end
            % if we passed everything, they are the same
            same = true;
        end
        
        % turn an Excel range string into dimensions
        function dim = excelRangeSize(range)
            separators = find(range==':'); % find the colon separators
            if numel(separators) == 0 % no separator --> single cell
                dim = [1 1];
            elseif numel(separators) == 1
                r1 = range(1:(separators-1));
                c1 = TemplateExtraction.excelCoordToPoint(r1);
                r2 = range((separators+1):end);
                c2 = TemplateExtraction.excelCoordToPoint(r2);
                dim = [abs(c2(1)-c1(1))+1, abs(c2(2)-c1(2))+1];
            else % can't have more than 1 separator
                EPVSession.error('TemplateExtraction','BadRange','Found more than one '':'' separator in range ''%s''',range);
            end
        end
        
        % Turn an excel coordinate into [[row col] [row col]]
        % Note: this requires the range to be in LT:RB format or a singleton
        function points = excelRangeToPoints(range)
            separators = find(range==':'); % find the colon separators
            if numel(separators) == 0 % no separator --> single cell
                c = TemplateExtraction.excelCoordToPoint(range);
                points = [c c];
            elseif numel(separators) == 1
                r1 = range(1:(separators-1));
                c1 = TemplateExtraction.excelCoordToPoint(r1);
                r2 = range((separators+1):end);
                c2 = TemplateExtraction.excelCoordToPoint(r2);
                points = [c1 c2];
            else % can't have more than 1 separator
                EPVSession.error('TemplateExtraction','BadRange','Found more than one '':'' separator in range ''%s''',range);
            end
        end

        
        % Turn an excel coordinate into [row col]
        function point = excelCoordToPoint(coord)
            try 
                % try a 1-character column name
                components = sscanf(coord,'%c%i');
                % if it fails, try a 2-character column name
                if numel(components)~=2, 
                    components = sscanf(coord,'%c%c%i'); 
                    assert(numel(components)==3);
                    % Assume column is ASCII upcase
                    char1 = components(1)-64; 
                    char2 = components(2)-64;
                    assert(char1>0 && char1<=26 && char2>0 && char2<=26);
                else
                    char1 = 0;
                    char2 = components(1)-64; % Assume column is ASCII upcase
                    assert(char2>0 && char2<=26);
                end;
                point(1) = components(end); % number is the row
                point(2) = char1*26 + char2;
            catch
                EPVSession.error('TemplateExtraction','BadRange','Could not interpret Excel coordinate ''%s''',coord);
            end
        end
        
        function raw = readExcelFromCache(cache,sheet,range)
            which = find(cellfun(@(x)(strcmp(sheet,x)),cache(:,1)));
            assert(numel(which)==1); % should match precisely one sheet in cache
            
            sheet_raw = cache{which,2};
            points = TemplateExtraction.excelRangeToPoints(range);
            % expand sheet if needed
            sheet_size = size(sheet_raw);
            if sheet_size(1)<points(3), sheet_raw((sheet_size(1)+1):points(3),:) = {nan}; end;
            if sheet_size(2)<points(4), sheet_raw(:,(sheet_size(2)+1):points(4)) = {nan}; end;
            raw = sheet_raw(points(1):points(3),points(2):points(4));
        end
    end
end
