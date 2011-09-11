%% GMT LTAO MODELING WITH OOMAO
% Demonstrate how to build the GMT LTAO system

%%
forceSettings = false;
matPath = fullfile('~','Desktop','Project','ANU','GMT','mcode','mat');
filename  = fullfile(matPath,'gmtNonSegSingleDmLtaoSettings.mat');
if exist(filename,'file') && ~forceSettings
    
    fprintf('   >>> LOAD SETTINGS FROM %s ....',upper(filename))
    load(filename)
    fprintf('\b\b\b\b!\n')
    
else
    %% Definition of the atmosphere
    % atm = atmosphere(photometry.V,0.15,30,...
    %     'altitude',[0,4,10]*1e3,...
    %     'fractionnalR0',[0.7,0.25,0.05],...
    %     'windSpeed',[5,10,20],...
    %     'windDirection',[0,pi/4,pi]);
    atm = gmtAtmosphere(1);
    
    %% Definition of the telescope
    nLenslet = 50;
    nPx = nLenslet*8;
    tel = telescope(25,...
        'obstructionRatio',0.4,...
        'fieldOfViewInArcMin',2.5,...
        'resolution',nPx,...
        'samplingTime',1/500);
%     tel = giantMagellanTelescope(...
%         'fieldOfViewInArcMin',2.5,...
%         'resolution',nPx,...
%         'samplingTime',1/500);
%     
    %% Definition of a calibration source
    ngs = source('wavelength',photometry.Na);
    
    %% Definition of the wavefront sensor
    wfs = shackHartmann(nLenslet,nPx,0.85);
    wfs.tag = 'LGS WFS';
    wfs.camera.exposureTime = tel.samplingTime;
    % Propagation of the calibration source to the WFS through the telescope
    ngs = ngs.*tel*wfs;
    wfs.INIT;
    +wfs;
    figure
    subplot(1,2,1)
    imagesc(wfs.camera)
    subplot(1,2,2)
    slopesDisplay(wfs)
    
    %% Definition of the deformable mirror
    bif = influenceFunction('monotonic',50/100);
    % Cut of the influence function
    % figure
    % show(bif)
    nActuator = nLenslet + 1;
    dm = deformableMirror(nActuator,...
        'modes',bif,...
        'resolution',nPx,...
        'validActuator',wfs.validActuator);
    %%% Interaction matrix: DM/WFS calibration
    ngs = ngs.*tel;
    dmWfsCalib = calibration(dm,wfs,ngs,ngs.wavelength/2);
    dmWfsCalib.threshold = 4e5;
    commandMatrix = dmWfsCalib.M;
    
    %% Tip-Tilt Sensor
    % Tip-Tilt source
    tt = source('wavelength',photometry.K);
    % GMT Tip-Tilt IR sensor
    tipTiltWfs = gmtInfraredQuadCellDetector(tel,1/tel.samplingTime,40e-3,tt);
    tipTiltWfs.tag = 'Tip-Tilt Sensor';
    tipTiltWfs.camera.readOutNoise = 0;
    tipTiltWfs.camera.photonNoise = false;
    tt = tt.*tel*tipTiltWfs;
    figure
    imagesc(tipTiltWfs.camera.frame)
    %% Interaction matrix: DM/TT sensor calibration
    dmTipTiltWfsCalib = calibration(dm,tipTiltWfs,tt,tt.wavelength/4);
    dmTipTiltWfsCalib.nThresholded = 0;
    commandTipTilt = dmTipTiltWfsCalib.M;
    
    %% Truth Sensor
    ttTruth = source('wavelength',photometry.H);
    truth = shackHartmann(10,10*10,0.75);
    truth.tag = 'Truth Sensor';
    truth.lenslets.fieldStopSize = 5;
    % Propagation of the calibration source to the WFS through the telescope
    ttTruth = ttTruth.*tel*truth;
    truth.INIT;
    +truth;
    figure
    imagesc(truth.camera)
    truth.camera.clockRate = 1/tel.samplingTime;
    %% Interaction matrix: DM/TT sensor calibration
    dmTruthCalib = calibration(dm,truth,ngs,ngs.wavelength/2);
    dmTruthCalib.nThresholded = 23;
    commandTruth = dmTruthCalib.M;

    %%
    lgs = source('asterism',{[6,arcsec(35),0]},'wavelength',photometry.Na,'height',90e3);
    ltaoMmse = linearMMSE(dm.nActuator,tel.D,atm,lgs,ngs,'pupil',dm.validActuator,'unit',-9);
    %%
    bifLowRes = influenceFunction('monotonic',0.5);
    dmLowRes = deformableMirror(wfs.lenslets.nLenslet+1,'modes',bifLowRes,...
        'resolution',wfs.lenslets.nLenslet+1,'validActuator',wfs.validActuator);
    F = dmLowRes.modes.modes(dmLowRes.validActuator,:);
    iP0 = F*commandMatrix;
    iP = repmat( {iP0} , 1 ,6 );
    iP = blkdiag(iP{:});
    M = ltaoMmse.mmseBuilder{1}*iP;
    iF = pinv(full(F));
    M = iF*M;
    
    % Combining the atmosphere and the telescope
    tel = tel+atm;
    figure
    imagesc(tel)
    
    fprintf('   >>> SAVING SETTINGS TO %s ....',upper(filename))
    save(filename)
    fprintf('\b\b\b\b!\n')

    
end

%%
%% The closed loop
% Resetting the DM command
dm.coefs = 0;
%%
% Propagation throught the atmosphere to the telescope
ngs=ngs.*tel;
lgs = lgs.*tel;
%%
% Saving the turbulence aberrated phase
turbPhase = ngs.meanRmPhase;
%%
% Propagation to the WFS
ngs=ngs*dm*wfs;
%%
% Display of turbulence and residual phase
figure(11)
rad2mic = 1e6/ngs.waveNumber;
h = imagesc([turbPhase,ngs.meanRmPhase]*rad2mic);
ax = gca;
axis equal tight
ylabel(colorbar,'WFE [\mum]')
%%
% Closed loop integrator gain:
loopGain = 0.5;
nIteration = 2000;
srcorma = sourceorama(fullfile(matPath,'gmtSingleDmLtao.h5'),[ngs;lgs(:)],nIteration*tel.samplingTime,tel,0.25);
%% Low pass filter
lpfTime = 1;
alpha = lpfTime/(1+lpfTime/tel.samplingTime);
lpfSlopes = 0;
%%
% closing the loop
total  = zeros(1,nIteration);
residue = zeros(1,nIteration);
dmCoefs   = zeros(dm.nValidActuator,1);
dmCoefsTt = zeros(dm.nValidActuator,1);
dmCoefsTruth = zeros(dm.nValidActuator,1);
dm.coefs  = 0;
ux = ones(1,length(lgs));
wfs.rmMeanSlopes = true;
truth.rmMeanSlopes = true;
% truthFrame = truth.camera.exposureTime*truth.camera.clockRate;
% hTruth = waitbar(0,'truth');
truth.camera.frameCount = 0;
tic
for kIteration=1:nIteration
    % Propagation throught the atmosphere to the telescope, +tel means that
    % all the layers move of one step based on the sampling time and the
    % wind vectors of the layers
    +srcorma;
%     ngs=ngs.*+tel;
    tt.resetPhase = ngs.opd*tt.waveNumber;
    ttTruth.resetPhase = ngs.opd*ttTruth.waveNumber;
    % Saving the turbulence aberrated phase
    turbPhase = ngs.meanRmPhase;
    % Variance of the atmospheric wavefront
    total(kIteration) = var(ngs);
    % Propagation to the WFS
    ngs=ngs*dm;
    lgs = lgs*dm*wfs;
   % Variance of the residual wavefront
    residue(kIteration) = var(ngs);
    % Computing the DM residual coefficients
    %     residualDmCoefs = M*wfs.slopes(:);
    
    % -.- TT sensing
    tt = tt*dm*tipTiltWfs;
    residualDmTtCoefs = commandTipTilt*tipTiltWfs.slopes;
    dmCoefsTt = dmCoefsTt - loopGain*residualDmTtCoefs;
    % TT sensing -.-
    
    % -.- Truth sensing
    ttTruth = ttTruth*dm*truth;
%     waitbar(truth.camera.frameCount/truthFrame)
    residualDmTruthCoefs = commandTruth*truth.slopes;
    dmCoefsTruth = dmCoefsTruth - residualDmTruthCoefs;
    % Truth sensing -.-
    
    %     % Integrating the DM coefficients
    %     dm.coefs = dm.coefs - loopGain*(residualDmCoefs + residualDmTtCoefs);
    
    % DM slopes
    S_DM = dmWfsCalib.D*dmCoefs;
    % LGS full turbulence slopes estimate
    S_LGS = wfs.slopes - S_DM*ux;
    lpfSlopes = alpha*S_LGS + (1-alpha)*lpfSlopes;
    S_LGS = S_LGS - lpfSlopes;
    % on-axis full turbulence DM command tomography estimate
    C_NGS = M*S_LGS(:);
    % on-axis residual turbulence DM command estimate
    C_res_NGS = C_NGS + dmCoefs;
    % integrator or (may be) low-pass filter (to check)
    dmCoefs   = dmCoefs   - loopGain*C_res_NGS;
    
    dm.coefs  = dmCoefs + dmCoefsTt + dmCoefsTruth;
    
    % Display of turbulence and residual phase
    set(h,'Cdata',[turbPhase,ngs.meanRmPhase]*rad2mic)
    title(ax,sprintf('#%4d/%4d',kIteration,nIteration))
    drawnow
end
clear srcorma
% close(hTruth)
toc
%%
% Piston removed phase variance
u = (0:nIteration-1).*tel.samplingTime;
atm.wavelength = ngs.wavelength;
totalTheory = phaseStats.zernikeResidualVariance(1,atm,tel);
atm.wavelength = photometry.V;
%%
% Phase variance to micron rms converter
rmsMicron = @(x) 1e6*sqrt(x).*ngs.wavelength/2/pi;
figure(12)
plot(u,rmsMicron(total),u([1,end]),rmsMicron(totalTheory)*ones(1,2),u,rmsMicron(residue))
grid
legend('Full','Full (theory)','Residue',0)
xlabel('Time [s]')
ylabel('Wavefront rms [\mum]')
